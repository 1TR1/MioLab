import Combine
import MioLibCore
import WebKit

// 浏览状态和 WebKit 生命周期由同一个主线程对象持有，SwiftUI 更新不会重复加载页面。
@MainActor final class WebBrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
  let webView: WKWebView
  @Published private(set) var url: URL?
  @Published private(set) var title = "网页阅读"
  @Published private(set) var progress = 0.0
  @Published private(set) var isLoading = false
  @Published private(set) var canGoBack = false
  @Published private(set) var canGoForward = false
  @Published private(set) var blocksAds = true
  @Published private(set) var configuring = false
  @Published private(set) var ready = false
  @Published private(set) var hasPage = false
  @Published private(set) var visitID = UUID()
  // 区分用户请求的书籍链接与重定向后的地址，避免把随后浏览的其他网页写入该书。
  @Published private(set) var pageRequestURL: URL?
  @Published var error: String?
  @Published var notice: String?
  private let initialURL: URL?
  private let loadsReadingCopies: Bool
  private let pageLoadTimeout: Duration
  private var requestedURL: URL?
  private var navigationSource: URL?
  private var observations: [NSKeyValueObservation] = []
  private static var cachedRules: WKContentRuleList?
  // 切章加载使用明确的完成回调和超时，不依赖隐藏视图中的 SwiftUI 状态监听。
  private var pageContinuation: CheckedContinuation<Void, Error>?
  private var pageTimeout: Task<Void, Never>?

  // 浏览器使用独立配置，不将广告规则应用到 Readium 的本地电子书视图。
  init(initialURL: URL?, loadsReadingCopies: Bool = false, pageLoadTimeout: Duration = .seconds(25)) {
    self.initialURL = initialURL
    self.loadsReadingCopies = loadsReadingCopies
    self.pageLoadTimeout = pageLoadTimeout
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    webView.isInspectable = false
    observations = [
      webView.observe(\.url, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
      webView.observe(\.title, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
      webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
      webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
      webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
      webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() }
    ]
  }

  // KVO 回调统一切回主线程，且通过弱引用避免关闭浏览器后残留会话。
  nonisolated private func scheduleRefresh() {
    Task { @MainActor [weak self] in self?.refresh() }
  }
  private func refresh() {
    url = webView.url.flatMap { try? WebAddress.url($0.absoluteString) }
    title = webView.title?.isEmpty == false ? webView.title! : webView.url?.host ?? "网页阅读"
    progress = webView.estimatedProgress
    isLoading = webView.isLoading
    canGoBack = webView.canGoBack
    canGoForward = webView.canGoForward
  }

  // 初次请求等待过滤规则编译完成；失败显示错误，用户可重试或明确关闭过滤。
  func prepare(blocksAds: Bool, startingAt destination: URL? = nil) async {
    guard !ready, !configuring else { return }
    do {
      try await configureFiltering(blocksAds)
      if let target = destination ?? initialURL { navigate(target.absoluteString) }
    } catch { self.error = "广告过滤准备失败：\(error.localizedDescription)。可重试，或在菜单中关闭过滤后访问。" }
  }

  // 切换规则后重载当前页，使已隐藏的广告容器及资源与开关状态一致。
  func configureFiltering(_ enabled: Bool) async throws {
    guard !configuring else { return }
    configuring = true
    defer { configuring = false }
    var rules: WKContentRuleList?
    if enabled {
      if let cached = Self.cachedRules { rules = cached }
      else {
        guard let store = WKContentRuleListStore.default() else { throw LibraryError.message("无法打开 WebKit 规则存储") }
        let cached = try? await store.contentRuleList(forIdentifier: WebContentFilter.identifier)
        let compiled: WKContentRuleList
        if let cached { compiled = cached }
        else {
          guard let result = try await store.compileContentRuleList(forIdentifier: WebContentFilter.identifier,
            encodedContentRuleList: WebContentFilter.rulesJSON()) else { throw LibraryError.message("WebKit 未生成广告过滤规则") }
          compiled = result
        }
        Self.cachedRules = compiled
        rules = compiled
      }
    }
    webView.configuration.userContentController.removeAllContentRuleLists()
    if let rules { webView.configuration.userContentController.add(rules) }
    // 缓存会话仅访问排入队列的正文，不接受网站自动打开的新窗口。
    webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = !enabled && !loadsReadingCopies
    blocksAds = enabled
    let wasReady = ready
    ready = true
    error = nil
    if wasReady, webView.url != nil { reload() }
  }

  // 地址栏和书签入口共用 URL 校验；加载错误保留输入地址以便修正或重试。
  func navigate(_ address: String) {
    guard ready, !configuring else { return }
    do {
      let target = try WebAddress.url(address)
      requestedURL = target
      navigationSource = target
      error = nil
      notice = nil
      webView.load(URLRequest(url: target))
    } catch { self.error = error.localizedDescription }
  }
  func reload() {
    error = nil
    if webView.url != nil { webView.reload() }
    else if let target = requestedURL ?? initialURL { navigate(target.absoluteString) }
  }
  func close() { webView.stopLoading(); finishPageLoad(CancellationError()) }

  // 章节读取等待 WebKit 完成解析，继续沿用网站 Cookie、编码和广告过滤规则。
  func loadPage(_ target: URL) async throws {
    try Task.checkCancellation()
    guard ready, !configuring, pageContinuation == nil else { throw LibraryError.message("浏览器尚未准备好，或正在加载另一章") }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pageContinuation = continuation
        // 自动缓存的尝试间隔更短，手动翻章继续允许慢站点使用原来的超时。
        pageTimeout = Task { [weak self, pageLoadTimeout] in
          do {
            try await Task.sleep(for: pageLoadTimeout)
            self?.webView.stopLoading()
            self?.finishPageLoad(LibraryError.message("章节网页加载超时"))
          } catch { /* 正常完成或取消时终止超时计时。 */ }
        }
        navigate(target.absoluteString)
        if let error { finishPageLoad(LibraryError.message(error)) }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.close() }
    }
    try Task.checkCancellation()
  }

  // 每次请求只恢复一次 continuation，后续取消或 WebKit 失败回调不会重复恢复。
  private func finishPageLoad(_ failure: Error? = nil) {
    pageTimeout?.cancel()
    pageTimeout = nil
    guard let continuation = pageContinuation else { return }
    pageContinuation = nil
    if let failure { continuation.resume(throwing: failure) }
    else { continuation.resume() }
  }

  // 只允许网页协议，拒绝页面尝试打开本地文件、脚本地址或强行唤起外部 App。
  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let target = navigationAction.request.url else { decisionHandler(.cancel); return }
    if target.absoluteString == "about:blank", navigationAction.targetFrame?.isMainFrame == false {
      decisionHandler(.allow)
      return
    }
    guard (try? WebAddress.url(target.absoluteString)) != nil else {
      if navigationAction.targetFrame?.isMainFrame != false { notice = "此链接无法在内置浏览器中打开，仅支持 HTTP／HTTPS 网页。" }
      decisionHandler(.cancel)
      return
    }
    // 服务端重定向沿用本次请求来源，用户点击、历史导航和脚本发起的新导航更新来源。
    if navigationAction.targetFrame?.isMainFrame != false,
      navigationAction.navigationType == .linkActivated || navigationAction.navigationType == .backForward
        || navigationAction.navigationType == .formSubmitted || navigationAction.navigationType == .formResubmitted
        || (navigationAction.navigationType == .other && hasPage && !isLoading) {
      navigationSource = try? WebAddress.url(target.absoluteString)
    }
    decisionHandler(.allow)
  }

  // 用户点击的新窗口链接在当前页打开；过滤开启时拒绝脚本自动弹出的新窗口。
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if loadsReadingCopies { return nil }
    guard !blocksAds || navigationAction.navigationType == .linkActivated else {
      notice = "已拦截自动弹窗"
      return nil
    }
    if let target = navigationAction.request.url, (try? WebAddress.url(target.absoluteString)) != nil {
      requestedURL = target
      navigationSource = target
      webView.load(navigationAction.request)
    }
    return nil
  }

  // 成功加载才开放收藏和记录访问；HTTP 错误页明确显示状态码。
  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    error = nil
    hasPage = false
  }
  func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse,
      response.statusCode >= 400 { error = "网站返回 HTTP \(response.statusCode)，可刷新或检查网址。" }
    decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    // 子框架中的下载不能中止正在等待的主文档。
    if navigationResponse.isForMainFrame && !navigationResponse.canShowMIMEType {
      notice = "此链接是下载文件，请通过文件导入入口添加电子书。"
      finishPageLoad(LibraryError.message("章节链接返回了下载文件，未切换正文"))
    }
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    refresh()
    hasPage = error == nil
    if hasPage { pageRequestURL = navigationSource ?? url; visitID = UUID() }
    finishPageLoad(error.map { LibraryError.message($0) })
  }

  // 取消请求属于正常的跳转或停止操作；其他网络错误展示原始原因并保留重试入口。
  private func failed(_ failure: Error) {
    guard (failure as NSError).code != NSURLErrorCancelled else { return }
    refresh()
    error = "网页加载失败：\(failure.localizedDescription)"
    finishPageLoad(failure)
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    hasPage = false
    error = "网页进程已停止，请刷新重试。"
    finishPageLoad(LibraryError.message("网页进程已停止，请刷新重试"))
  }
}
