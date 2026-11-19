import MioLibCore
import SwiftUI
import WebKit

// 浏览器覆盖整个阅读区，地址栏与底部操作遵循安全区，关闭后回到原来的收藏列表。
struct WebBrowserScreen: View {
  @ObservedObject var model: AppModel
  // 网页书籍保留稳定书目；原网页与阅读模式是同一本书的两种打开方式。
  let book: Book?
  @StateObject private var browser: WebBrowserSession
  @StateObject private var chapterNavigation: WebReaderNavigation
  @ObservedObject private var cache: WebBookCache
  @Environment(\.dismiss) private var dismiss
  @FocusState private var addressFocused: Bool
  @State private var address: String
  @State private var editor: WebBookmarkDraft?
  @State private var savingFilter = false
  @State private var readingBook: Book?
  @State private var initializingMode: Bool
  @State private var originalPage: URL?
  // 阅读按钮只等待已确认的下载。首次选择和两种模式的菜单共用一个缓存面板。
  @State private var waitingToRead = false
  @State private var changingReadingMode = false
  @State private var exporting: WebBookmark?
  @State private var exportedBook: Book?
  @State private var pendingExport: Book?
  @State private var cachePrompt: Book?
  @State private var readAfterCachePrompt = false
  @State private var confirmedCacheBook: Book?
  init(model: AppModel, initialURL: URL?, book: Book? = nil) {
    self.model = model
    self.book = book
    _browser = StateObject(wrappedValue: WebBrowserSession(initialURL: initialURL))
    _chapterNavigation = StateObject(wrappedValue: WebReaderNavigation(model: model))
    _cache = ObservedObject(wrappedValue: model.webBookCache)
    _initializingMode = State(initialValue: book != nil)
    _address = State(initialValue: initialURL?.absoluteString ?? "")
  }

  // 原网页和阅读器共用一层全屏书籍窗口，阅读器退出直接关闭书籍。
  var body: some View {
    ZStack {
      if initializingMode {
        // 读取书目的缓存记录和阅读模式记忆后决定初始界面。
        ProgressView("正在打开书籍…")
      } else if let readingBook {
        WebBookReader(model: model, book: readingBook, navigation: chapterNavigation) { url in
          await showOriginalPage(url, for: readingBook)
        } onChooseCacheVolumes: {
          // 已在阅读器内时，只打开选择面板，关闭后继续在原页阅读。
          presentCachePrompt(try await currentBook(readingBook), opensReader: false)
        }
      } else {
        browserPage
      }
    }
    .task { await openInitialMode() }
    // 选择器确认后才交回下载任务；按钮跳过和下拉关闭都直接继续打开。
    .sheet(item: $cachePrompt, onDismiss: finishCachePrompt) { current in
      WebCacheSelectionView(model: model, book: current) { confirmedCacheBook = $0 }
    }
    .onDisappear { browser.close() }
  }

  // 网页会话独立保存，切换阅读模式时不丢失已有浏览记录和登录。
  private var browserPage: some View {
    NavigationStack {
      VStack(spacing: 0) {
        addressBar
        if browser.configuring { ProgressView("正在准备广告过滤…").font(.caption).padding(8) }
        if browser.isLoading { ProgressView(value: browser.progress).progressViewStyle(.linear) }
        if let error = browser.error, !waitingToRead { message(error, isError: true) }
        if let notice = browser.notice { message(notice, isError: false) }
        // 缓存正文随时可用，网络失败时也保留明确的阅读模式按钮。
        if let book {
          HStack {
            Image(systemName: "book.closed").foregroundStyle(.secondary)
            Text(book.title).font(.subheadline).lineLimit(1)
            Spacer(minLength: 8)
            if waitingToRead { ProgressView().controlSize(.small) }
            Button(waitingToRead ? "取消等待" : "阅读模式") { toggleReading(book) }
              .buttonStyle(.bordered).controlSize(.large).disabled(model.maintenance || changingReadingMode)
          }.padding(.horizontal, 12).padding(.vertical, 6)
          if let status = cache.statuses[book.id] { cacheStatus(book, status: status) }
        }
        ZStack {
          WebBrowserSurface(browser: browser)
          if browser.url == nil && !browser.isLoading {
            ContentUnavailableView("输入网址，开始阅读", systemImage: "globe",
              description: Text("可以直接输入域名，也可以粘贴完整链接。\n打开网页后点击下方书签，即可保存。"))
              .allowsHitTesting(false)
          }
        }
      }.background(Color(.systemBackground))
        .navigationTitle(browser.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              Button(browser.blocksAds ? "关闭广告过滤" : "开启广告过滤",
                systemImage: browser.blocksAds ? "shield.slash" : "shield") { changeFilter() }
                .disabled(browser.configuring || savingFilter)
              if let url = browser.url { ShareLink(item: url) { Label("分享当前链接", systemImage: "square.and.arrow.up") } }
              if let source = book?.webURL {
                Button("重新打开书籍链接", systemImage: "book.closed") {
                  browser.navigate(source.absoluteString)
                }.disabled(!browser.ready || browser.configuring)
              }
              if let book {
                Button("选择缓存卷", systemImage: "arrow.down.circle") {
                  Task {
                    do {
                      let current = try await currentBook(book)
                      presentCachePrompt(current, opensReader: waitingToRead || current.webReaderEnabled == true)
                    }
                    catch { browser.error = error.localizedDescription }
                  }
                }.disabled(model.maintenance || changingReadingMode)
              }
              if browser.hasPage {
                Button("将当前网址导出至书架", systemImage: "books.vertical") { exportCurrent() }
                  .disabled(model.maintenance)
              }
              Text("过滤常见广告源、广告位与自动弹窗，无法覆盖全部网站。网页异常时可关闭后重试。")
            } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("网页选项")
          }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
    }
    .task { await prepareOriginalPage() }
    .onChange(of: browser.url) { _, url in if !addressFocused, let url { address = url.absoluteString } }
    .onChange(of: browser.visitID) { _, _ in
      if let url = browser.url { model.run { try await $0.markWebBookmarkOpened(url) } }
      if let book, let source = book.webURL, browser.pageRequestURL == source {
        model.run { try await $0.markWebBookOpened(book.id, source: source) }
      }
    }
    // 首章写入就进入阅读，后台下载进度的频繁变化不会重复打开窗口。
    .onChange(of: book.flatMap { cache.statuses[$0.id]?.readingPath }, initial: true) { _, path in
      if let book, path != nil, waitingToRead { Task { await openWaitingCopy(book) } }
    }
    .onChange(of: book.flatMap { cache.statuses[$0.id]?.phase }) { _, phase in
      if case .failed? = phase { waitingToRead = false }
      if phase == .paused { waitingToRead = false }
    }
    .sheet(item: $editor) { WebBookmarkEditor(model: model, draft: $0) }
    .sheet(item: $exporting, onDismiss: { exportedBook = pendingExport; pendingExport = nil }) { bookmark in
      WebBookmarkExportView(model: model, bookmark: bookmark) { pendingExport = $0 }
    }
    .alert("已保存至书架", isPresented: Binding(get: { exportedBook != nil }, set: { if !$0 { exportedBook = nil } })) {
      Button("好", role: .cancel) { exportedBook = nil }
    } message: { Text("可以从书架打开，并编辑标题、封面和链接。") }
  }

  // 下载状态和暂停、继续入口留在原网页，避免阅读时遮挡正文。
  private func cacheStatus(_ book: Book, status: WebBookCache.Status) -> some View {
    HStack(spacing: 8) {
      Text(status.label).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
      switch status.phase {
      case .queued, .downloading, .retrying: Button("暂停") { cache.pause(book.id) }
      case .paused, .systemPaused, .failed:
        Button("继续缓存") {
          // 继续时读取最新选择，窗口刚打开时的书目可能仍记录上一次选择。
          Task {
            do { cache.start(try await currentBook(book)) }
            catch { browser.error = error.localizedDescription }
          }
        }.disabled(model.maintenance)
      case .complete: EmptyView()
      }
    }.font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 6)
  }

  // 地址输入拥有明确的“前往”按钮，键盘提交也走同一个加载入口。
  private var addressBar: some View {
    HStack(spacing: 8) {
      Image(systemName: browser.blocksAds && browser.ready ? "shield.lefthalf.filled" : "globe")
        .foregroundStyle(browser.blocksAds && browser.ready ? Color.green : Color.secondary)
        .accessibilityLabel(browser.blocksAds && browser.ready ? "广告过滤已开启" : "广告过滤未开启")
      TextField("输入网址", text: $address).keyboardType(.URL).textInputAutocapitalization(.never)
        .autocorrectionDisabled().focused($addressFocused).submitLabel(.go).onSubmit { go() }
        .accessibilityLabel("网页地址")
      Button("前往") { go() }.disabled(!browser.ready || browser.configuring || address.isEmpty)
    }.padding(12).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
      .padding(.horizontal, 12).padding(.bottom, 8)
  }

  // 每个导航按钮至少有 44 点触控区，收藏当前最终网址而非最初输入的重定向地址。
  private var controls: some View {
    HStack {
      Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
        .disabled(!browser.canGoBack || browser.configuring).accessibilityLabel("后退")
      Spacer()
      Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
        .disabled(!browser.canGoForward || browser.configuring).accessibilityLabel("前进")
      Spacer()
      Button {
        if browser.isLoading { browser.webView.stopLoading() }
        else if browser.ready { browser.reload() }
        else { Task { await browser.prepare(blocksAds: model.webPreferences.blocksAds) } }
      } label: { Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise").frame(width: 44, height: 44) }
        .disabled(browser.configuring).accessibilityLabel(browser.isLoading ? "停止加载" : "刷新网页")
      Spacer()
      Button { saveCurrent() } label: {
        Image(systemName: isSaved ? "bookmark.fill" : "bookmark").frame(width: 44, height: 44)
      }.disabled(!browser.hasPage || model.maintenance).accessibilityLabel(isSaved ? "编辑当前收藏" : "收藏当前网址")
    }.font(.title3).padding(.horizontal, 16).padding(.vertical, 4).background(.regularMaterial)
  }

  // 错误留在浏览器内部；弹窗拦截提示可单独关闭，不打断正文阅读。
  private func message(_ text: String, isError: Bool) -> some View {
    HStack(alignment: .top) {
      Text(text).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
      Button {
        if isError { browser.error = nil } else { browser.notice = nil }
      } label: { Image(systemName: "xmark").frame(width: 32, height: 32) }.accessibilityLabel("关闭提示")
    }.padding(.leading, 12).padding(.vertical, 4).foregroundStyle(isError ? Color.red : Color.secondary)
      .background(Color(.secondarySystemBackground))
  }
  private var isSaved: Bool { model.webBookmarks.contains { $0.url == browser.url } }
  private func go() { addressFocused = false; browser.navigate(address) }
  private func saveCurrent() {
    guard let url = browser.url else { return }
    if let bookmark = model.webBookmarks.first(where: { $0.url == url }) { editor = WebBookmarkDraft(bookmark) }
    else { editor = WebBookmarkDraft(title: browser.title, url: url) }
  }

  // 从当前页导出时先保存收藏，再使用同一目标书架选择面板。
  private func exportCurrent() {
    guard let url = browser.url, let repository = model.repository else { return }
    Task {
      do {
        if let saved = model.webBookmarks.first(where: { $0.url == url }) { exporting = saved }
        else {
          exporting = try await repository.saveWebBookmark(address: url.absoluteString, title: browser.title)
          try await model.reload()
        }
      } catch { browser.error = error.localizedDescription }
    }
  }

  // 有缓存记录时按记住的模式直接打开，未有记录才显示卷选择。
  private func openInitialMode() async {
    guard initializingMode, let book else { return }
    do {
      let current = try await currentBook(book)
      let opensReader = current.webReaderEnabled == true || model.requestedAnnotation?.bookID == current.id
      guard current.hasWebCacheRecord else {
        presentCachePrompt(current, opensReader: opensReader)
        return
      }
      // 已经运行的任务可继续等待首章；打开书籍本身不会启动下载。
      if opensReader {
        if current.hasWebReadingCopy { readingBook = current }
        else { waitingToRead = cacheInProgress(current.id) }
      }
      initializingMode = false
    } catch is CancellationError {} catch {
      browser.error = error.localizedDescription
      initializingMode = false
    }
  }

  // 打开、阅读按钮和右上角菜单共用选择器。弹窗关闭后再处理阅读入口。
  private func presentCachePrompt(_ book: Book, opensReader: Bool) {
    readAfterCachePrompt = opensReader
    confirmedCacheBook = nil
    cachePrompt = book
  }

  // 关闭面板后恢复书籍界面。只有确认回调填写的书目才能启动新任务。
  private func finishCachePrompt() {
    let opensReader = readAfterCachePrompt
    let confirmed = confirmedCacheBook
    readAfterCachePrompt = false
    confirmedCacheBook = nil
    if let confirmed { cache.start(confirmed, prioritize: opensReader && !confirmed.hasWebReadingCopy) }
    guard opensReader, let book else { initializingMode = false; return }
    Task {
      defer { initializingMode = false }
      do {
        let current = try await currentBook(book)
        if current.hasWebReadingCopy { readingBook = current; waitingToRead = false }
        else if confirmed != nil { waitingToRead = true }
      } catch { browser.error = error.localizedDescription; waitingToRead = false }
    }
  }

  // 有正文时直接进入阅读模式。正文未就绪时等待已确认的任务，或由用户再次选卷。
  private func toggleReading(_ book: Book) {
    guard let repository = model.repository, !changingReadingMode else { return }
    let enabled = !waitingToRead
    changingReadingMode = true
    Task {
      defer { changingReadingMode = false }
      do {
        try await repository.setWebReaderEnabled(enabled, for: book)
        guard enabled else { waitingToRead = false; return }
        let current = try await currentBook(book)
        if current.hasWebReadingCopy {
          readingBook = current
        } else if cacheInProgress(current.id) {
          waitingToRead = true
          await openWaitingCopy(current)
        } else if current.hasWebCacheRecord {
          // 有记录但正文还不可用时，提示手动入口，避免再次主动弹窗。
          browser.notice = "离线正文尚未就绪，可从右上角菜单选择缓存卷。"
        } else {
          presentCachePrompt(current, opensReader: true)
        }
      } catch { browser.error = error.localizedDescription }
    }
  }

  // 只有还在队列里的任务可以等待；用户暂停与最终失败都需要手动继续。
  private func cacheInProgress(_ bookID: UUID) -> Bool {
    switch cache.statuses[bookID]?.phase {
    case .queued, .downloading, .retrying, .systemPaused: return true
    default: return false
    }
  }

  // 显式查看原网页才关闭该书的模式记忆。左上角退出走全屏窗口的关闭动作。
  private func showOriginalPage(_ url: URL, for book: Book) async {
    guard !changingReadingMode else { return }
    changingReadingMode = true
    defer { changingReadingMode = false }
    do { try await model.repository?.setWebReaderEnabled(false, for: book) }
    catch { browser.error = error.localizedDescription }
    waitingToRead = false
    originalPage = url
    readingBook = nil
  }

  // 从离线阅读切回时，首次加载直接使用所在章的网址。
  private func prepareOriginalPage() async {
    let target = originalPage
    if browser.ready {
      if let target, target != browser.url { browser.navigate(target.absoluteString) }
    } else {
      await browser.prepare(blocksAds: model.webPreferences.blocksAds, startingAt: target)
    }
    if browser.ready { originalPage = nil }
  }

  // 首章落盘后切入阅读器。用户已经取消等待时保持原网页。
  private func openWaitingCopy(_ book: Book) async {
    do {
      let current = try await currentBook(book)
      if waitingToRead, current.hasWebReadingCopy {
        waitingToRead = false
        readingBook = current
      }
    } catch is CancellationError {} catch {
      waitingToRead = false
      browser.error = error.localizedDescription
    }
  }

  // 使用同一来源的最新快照，避免改链或恢复时打开旧的缓存路径。
  private func currentBook(_ original: Book) async throws -> Book {
    guard let repository = model.repository else { throw LibraryError.message("书库尚未就绪") }
    let current = try await repository.book(original.id)
    try Task.checkCancellation()
    guard current.deletedAt == nil, current.originalPath == original.originalPath else {
      throw LibraryError.message("网页书籍已改变，请重新打开")
    }
    return current
  }

  // 应用规则成功后保存开关，失败保留原设置；首次过滤准备失败时也能选择关闭后访问。
  private func changeFilter() {
    let next = !browser.blocksAds
    savingFilter = true
    Task {
      defer { savingFilter = false }
      do {
        let wasReady = browser.ready
        try await browser.configureFiltering(next)
        let prefs = WebPreferences(blocksAds: next)
        guard let repository = model.repository else { throw LibraryError.message("书库尚未就绪，过滤设置未保存") }
        try await repository.saveWebPreferences(prefs)
        model.webPreferences = prefs
        if !wasReady, !address.isEmpty { browser.navigate(address) }
      } catch { browser.error = error.localizedDescription }
    }
  }
}

// 阅读窗口保持原来的呈现状态，切章或打开已更新的目录时只重建内部阅读器。
private struct WebBookReader: View {
  let model: AppModel
  let navigation: WebReaderNavigation
  let showOriginalPage: (URL) async -> Void
  let onChooseCacheVolumes: () async throws -> Void
  @State private var book: Book
  @State private var panel: ReaderPanel?
  @State private var revision = UUID()
  init(model: AppModel, book: Book, navigation: WebReaderNavigation,
    showOriginalPage: @escaping (URL) async -> Void, onChooseCacheVolumes: @escaping () async throws -> Void)
  {
    self.model = model
    self.navigation = navigation
    self.showOriginalPage = showOriginalPage
    self.onChooseCacheVolumes = onChooseCacheVolumes
    _book = State(initialValue: book)
  }
  var body: some View {
    ReaderScreen(model: model, book: book, webNavigation: navigation, initialPanel: panel,
      onShowOriginalPage: showOriginalPage, onChooseCacheVolumes: onChooseCacheVolumes) { updated, nextPanel in
      book = updated
      panel = nextPanel
      revision = UUID()
    }.id(revision)
  }
}

// Representable 仅承载已有 WKWebView，导航行为全部由会话显式驱动。
private struct WebBrowserSurface: UIViewRepresentable {
  let browser: WebBrowserSession
  func makeUIView(context: Context) -> WKWebView { browser.webView }
  func updateUIView(_ uiView: WKWebView, context: Context) {}
}
