import MioLibCore
import PDFKit
import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer
import SwiftUI
import WebKit

// 阅读位置、目录与搜索结果统一交给会话，SwiftUI 工具栏不会重建底层阅读器。
struct ReaderEntry: Identifiable {
  let id = UUID()
  let title: String
  let depth: Int
  var link: ReadiumShared.Link?
  var page: Int?
}
// 保留书内目录层级；没有跳转目标的标题也保留，作为下级章节的分组索引。
struct ReaderOutlineNode: Identifiable {
  let entry: ReaderEntry
  var children: [ReaderOutlineNode]?
  var id: UUID { entry.id }
  static func build(_ entries: [ReaderEntry]) -> [ReaderOutlineNode] {
    var cursor = 0
    func level(_ depth: Int) -> [ReaderOutlineNode] {
      var nodes: [ReaderOutlineNode] = []
      while cursor < entries.count && entries[cursor].depth >= depth {
        let entry = entries[cursor]
        cursor += 1
        let nested = cursor < entries.count && entries[cursor].depth > entry.depth
          ? level(entries[cursor].depth) : []
        nodes.append(ReaderOutlineNode(entry: entry, children: nested.isEmpty ? nil : nested))
      }
      return nodes
    }
    return entries.isEmpty ? [] : level(entries[0].depth)
  }
}
struct ReaderMatch: Identifiable {
  let id = UUID()
  let title: String
  let snippet: String
  var locator: Locator?
  var page: Int?
  var range: NSRange?
}
@MainActor final class ReaderSession: ObservableObject {
  let model: AppModel
  let book: Book
  // 封面预览复用阅读器，但不写进度、最近阅读或标注。
  let savesProgress: Bool
  @Published var loading = true
  @Published var error: String?
  @Published var controls = false
  @Published var progress: Double
  @Published var positionLabel = ""
  @Published var entries: [ReaderEntry] = [] {
    didSet { outline = ReaderOutlineNode.build(entries) }
  }
  @Published var outline: [ReaderOutlineNode] = []
  @Published var currentPage = 1
  @Published var pageCount = 0
  // 实际屏幕分页独立于 Readium 的稳定位置编号，不参与进度存储或目录跳转。
  @Published var renderedPage: ReaderRenderedPage?
  var footerLabel: String {
    if loading { return "" }
    if book.format == .pdf || publication?.metadata.layout == .fixed {
      return pageCount > 0 ? "\(currentPage)/\(pageCount)" : ""
    }
    if !model.preferences.scroll, let renderedPage { return "\(renderedPage.current)/\(renderedPage.count)" }
    return "\(ReadingProgress.percent(progress))%"
  }
  var footerAccessibilityLabel: String {
    if book.format == .pdf || publication?.metadata.layout == .fixed {
      return "第 \(currentPage) 页，共 \(pageCount) 页"
    }
    if !model.preferences.scroll, let renderedPage {
      return "本节第 \(renderedPage.current) 页，共 \(renderedPage.count) 页"
    }
    return "全书进度 \(ReadingProgress.percent(progress))%"
  }
  @Published var matches: [ReaderMatch] = []
  @Published var searching = false
  @Published var searchMessage = ""
  @Published var draft: Annotation?
  lazy var host = ReaderHostController(session: self)
  var publication: Publication?
  var positions: [Locator] = []
  var latestPosition: ReadingPosition?
  private var saveTask: Task<Void, Never>?
  private var searchTask: Task<Void, Never>?
  init(model: AppModel, book: Book, savesProgress: Bool = true) {
    self.model = model
    self.book = book
    self.savesProgress = savesProgress
    progress = book.progress
    latestPosition = book.position
  }

  // 准确定位随内容保存；进度的频繁变化合并为半秒一次数据库写入。
  func moved(to position: ReadingPosition, progress: Double, label: String) {
    latestPosition = position
    self.progress = ReadingProgress.normalized(progress)
    positionLabel = label
    guard savesProgress else { return }
    saveTask?.cancel()
    let value = self.progress
    saveTask = Task {
      do {
        try await Task.sleep(for: .milliseconds(500))
        try Task.checkCancellation()
        try await model.repository?.updateProgress(
          bookID: book.id, position: position, progress: value)
      } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
  }
  func flush() async {
    guard savesProgress else { return }
    host.captureCurrentPosition()
    saveTask?.cancel()
    if let position = latestPosition {
      do {
        try await model.repository?.updateProgress(
          bookID: book.id, position: position, progress: progress)
      } catch { model.message = error.localizedDescription }
    }
  }
  func seek(_ value: Double) {
    if let document = host.pdfView?.document, document.pageCount > 0 {
      host.goPDF(page: min(document.pageCount - 1, Int(value * Double(document.pageCount))))
    } else if !positions.isEmpty {
      let index = min(positions.count - 1, max(0, Int(value * Double(positions.count - 1))))
      // 滑块拉至最右端时定位最后资源的尾端，避免位置列表的最后采样点尚未到末页。
      let target = value >= 1 ? positions[index].copy(locations: {
        $0.progression = 1
        $0.totalProgression = 1
        $0.fragments = []
      }) : positions[index]
      Task { _ = await host.epub?.go(to: target) }
    }
  }
  // PDF 和固定版式 EPUB 使用页码，流式文字使用稳定位置编号，避免字号变化使索引失效。
  var pageUnit: String { book.format == .pdf || publication?.metadata.layout == .fixed ? "页" : "位置" }
  func navigatePage(_ page: Int) {
    guard pageCount > 0 else { return }
    let index = ReaderPageNavigation.index(page, count: pageCount)
    if host.pdfView != nil { host.goPDF(page: index) }
    else if positions.indices.contains(index) {
      // 最后一个位置指向资源末端，与进度滑块和末页 100% 的行为一致。
      let target = index == positions.count - 1 ? positions[index].copy(locations: {
        $0.progression = 1
        $0.totalProgression = 1
        $0.fragments = []
      }) : positions[index]
      Task { _ = await host.epub?.go(to: target) }
    }
  }
  func navigate(_ entry: ReaderEntry) {
    if let page = entry.page {
      host.goPDF(page: page)
    } else if let link = entry.link {
      Task { _ = await host.epub?.go(to: link) }
    }
  }
  func navigate(_ match: ReaderMatch) {
    if let locator = match.locator {
      Task { _ = await host.epub?.go(to: locator) }
    } else if let page = match.page {
      host.goPDF(page: page)
      if let range = match.range, let pdf = host.pdfView,
        let selection = pdf.document?.page(at: page)?.selection(for: range)
      {
        pdf.setCurrentSelection(selection, animate: true)
        pdf.go(to: selection)
      }
    }
  }
  func navigate(_ note: Annotation) {
    if let page = note.position.page {
      host.goPDF(page: page)
    } else if let json = note.position.locatorJSON, let locator = try? Locator(jsonString: json) {
      Task { _ = await host.epub?.go(to: locator) }
    }
  }

  // 搜索任务随输入取消；PDF 用独立文档在后台检索，结果以页码和范围回传。
  func search(_ query: String) {
    searchTask?.cancel()
    matches = []
    searchMessage = ""
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else {
      searching = false
      return
    }
    searching = true
    searchTask = Task {
      do {
        try await Task.sleep(for: .milliseconds(280))
        try Task.checkCancellation()
        if book.format == .pdf, let url = model.fileURL(book.readingPath) {
          let worker = Task.detached(priority: .userInitiated) { () -> [ReaderMatch] in
            guard let document = PDFKit.PDFDocument(url: url) else { return [] }
            var output: [ReaderMatch] = []
            for index in 0..<document.pageCount {
              if Task.isCancelled { break }
              guard let text = document.page(at: index)?.string else { continue }
              var start = text.startIndex
              while start < text.endIndex,
                let range = text.range(
                  of: term, options: .caseInsensitive, range: start..<text.endIndex)
              {
                let lower =
                  text.index(range.lowerBound, offsetBy: -32, limitedBy: text.startIndex)
                  ?? text.startIndex
                let upper =
                  text.index(range.upperBound, offsetBy: 48, limitedBy: text.endIndex)
                  ?? text.endIndex
                output.append(
                  ReaderMatch(
                    title: "第 \(index+1) 页", snippet: String(text[lower..<upper]), page: index,
                    range: NSRange(range, in: text)))
                if output.count >= 1000 { return output }
                start = range.upperBound
              }
            }
            return output
          }
          let result = await withTaskCancellationHandler(
            operation: { await worker.value }, onCancel: { worker.cancel() })
          try Task.checkCancellation()
          matches = result
        } else if let publication {
          guard publication.isSearchable else { throw LibraryError.message("此书没有可搜索的文字内容") }
          let iterator = try await publication.search(query: term).get()
          while let page = try await iterator.next().get() {
            try Task.checkCancellation()
            matches += page.locators.map {
              ReaderMatch(
                title: $0.title ?? "正文",
                snippet: ($0.text.before ?? "") + ($0.text.highlight ?? "") + ($0.text.after ?? ""),
                locator: $0)
            }
            if matches.count >= 1000 { break }
          }
        }
        searching = false
        searchMessage =
          matches.isEmpty
          ? (book.format == .pdf ? "未找到结果；扫描 PDF 需要原文件具有文字层。" : "未找到匹配文字")
          : (matches.count >= 1000 ? "显示前 1000 条结果，请缩小搜索范围" : "找到 \(matches.count) 条结果")
      } catch is CancellationError {} catch {
        searching = false
        searchMessage = error.localizedDescription
      }
    }
  }

  // 高亮直接保存，批注先打开编辑器，书签和扫描页笔记也使用同一个位置模型。
  func addBookmark() {
    guard let position = latestPosition else { return }
    save(
      Annotation(
        bookID: book.id, kind: .bookmark, position: position, quote: positionLabel,
        chapter: positionLabel))
  }
  func pageNote() {
    guard let position = latestPosition else { return }
    draft = Annotation(bookID: book.id, kind: .note, position: position, chapter: positionLabel)
  }
  func save(_ note: Annotation) {
    guard savesProgress else { return }
    Task {
      do {
        try await model.repository?.saveAnnotation(note)
        try await model.reload()
        host.applyAnnotations()
      } catch { self.error = error.localizedDescription }
    }
  }
  func remove(_ note: Annotation) {
    guard savesProgress else { return }
    Task {
      do {
        try await model.repository?.deleteAnnotation(note.id)
        try await model.reload()
        host.applyAnnotations()
      } catch { self.error = error.localizedDescription }
    }
  }
  var notes: [Annotation] { model.notes.filter { $0.bookID == book.id } }
  func close() {
    searchTask?.cancel()
    saveTask?.cancel()
    host.cancelLoading()
  }
}

// UIKit 容器负责原生选择菜单、PDF 手势与 Readium delegate，避免覆盖文字选择层。
@MainActor
final class ReaderHostController: UIViewController, EPUBNavigatorDelegate,
  UIGestureRecognizerDelegate
{
  private weak var session: ReaderSession?
  private var loadTask: Task<Void, Never>?
  private var pageObserver: NSObjectProtocol?
  private var lastPreferences: ReaderPreferences?
  var epub: EPUBNavigatorViewController?
  var pdfView: MioPDFView?
  private var ready = false
  private var annotatedPDFPages:Set<Int>=[]
  init(session: ReaderSession) {
    self.session = session
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("不使用 Storyboard") }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    loadTask = Task { await load() }
  }
  deinit {
    loadTask?.cancel()
    if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
  }

  // 解析通过异步 API 调用，加载状态仅覆盖内容区，始终保留关闭入口。
  private func load() async {
    guard let session, let url = session.model.fileURL(session.book.readingPath) else { return }
    do {
      if session.book.format == .pdf {
        try await loadPDF(url)
      } else {
        let client = DefaultHTTPClient()
        let retriever = AssetRetriever(httpClient: client)
        let opener = PublicationOpener(
          parser: DefaultPublicationParser(
            httpClient: client, assetRetriever: retriever, pdfFactory: DefaultPDFDocumentFactory()))
        let asset = try await retriever.retrieve(url: url.anyURL.absoluteURL!).get()
        let publication = try await opener.open(
          asset: asset, allowUserInteraction: false, sender: self
        ).get()
        try Task.checkCancellation()
        session.publication = publication
        let saved = session.savesProgress
          ? session.model.requestedAnnotation?.position ?? session.book.position : session.book.position
        let locator = saved?.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        var config = EPUBNavigatorViewController.Configuration()
        config.preferences = epubPreferences(resolvedPreferences(session.model.preferences))
        config.preloadPreviousPositionCount = 1
        config.preloadNextPositionCount = 2
        config.editingActions = session.savesProgress ?
          EditingAction.defaultActions + [
            EditingAction(title: "高亮", action: #selector(highlightSelection)),
            EditingAction(title: "批注", action: #selector(annotateSelection)),
          ] : []
        let controller = try EPUBNavigatorViewController(
          publication: publication, initialLocation: locator, config: config)
        epub = controller
        controller.delegate = self
        controller.addObserver(
          .activate { [weak self] event in
            guard let self, let session = self.session else { return false }
            let fraction = event.location.x / max(1, self.view.bounds.width)
            if fraction > 0.25 && fraction < 0.75 {
              session.controls.toggle()
              return true
            }
            return false
          })
        addChild(controller)
        view.addSubview(controller.view)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.didMove(toParent: self)
        session.entries = flatten((try? await publication.tableOfContents().get()) ?? [])
        session.positions = (try? await publication.positions().get()) ?? []
        session.pageCount = session.positions.count
        if let current = controller.currentLocation { updateEPUBProgress(controller, locator: current) }
        applyAnnotations()
      }
      ready = true
      session.loading = false
      applyPreferences(session.model.preferences)
      if session.savesProgress { session.model.requestedAnnotation = nil }
      if let position = session.latestPosition, session.book.lastOpenedAt == nil {
        session.moved(to: position, progress: session.progress, label: session.positionLabel)
      }
    } catch is CancellationError {} catch {
      session.error = error.localizedDescription
      session.loading = false
    }
  }
  private func flatten(_ links: [ReadiumShared.Link], depth: Int = 0) -> [ReaderEntry] {
    links.flatMap { link in
      [ReaderEntry(title: link.title ?? "章节", depth: depth, link: link)]
        + flatten(link.children, depth: depth + 1)
    }
  }

  // PDF 文档在后台解析，屏幕布局与选择行为仍由系统 PDFView 管理。
  private func loadPDF(_ url: URL) async throws {
    guard let session else { return }
    guard
      let document = await Task.detached(
        priority: .userInitiated, operation: { PDFKit.PDFDocument(url: url) }
      ).value, document.pageCount > 0
    else { throw LibraryError.message("PDF 文件损坏或没有可显示的页面") }
    guard !document.isLocked else { throw LibraryError.message("此 PDF 已加密，请先使用已解锁的文件") }
    let pdf = MioPDFView()
    pdfView = pdf
    pdf.owner = session.savesProgress ? self : nil
    pdf.document = document
    pdf.autoScales = true
    pdf.displayDirection = .vertical
    pdf.displayMode = .singlePageContinuous
    pdf.frame = view.bounds
    pdf.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(pdf)
    let gesture = UITapGestureRecognizer(target: self, action: #selector(pdfTapped(_:)))
    gesture.cancelsTouchesInView = false
    gesture.delegate = self
    pdf.addGestureRecognizer(gesture)
    pageObserver = NotificationCenter.default.addObserver(
      forName: .PDFViewPageChanged, object: pdf, queue: .main
    ) { [weak self] _ in Task { @MainActor in self?.pdfMoved() } }
    session.entries = pdfOutline(document.outlineRoot, document: document)
    // 无内置目录时不再把每一页伪装成章节，页码入口单独放在目录下方。
    session.pageCount = document.pageCount
    view.layoutIfNeeded()
    let saved = session.savesProgress
      ? session.model.requestedAnnotation?.position ?? session.book.position : session.book.position
    if let index = saved?.page,
      let page = document.page(at: min(document.pageCount - 1, max(0, index)))
    {
      let bounds = page.bounds(for: .cropBox)
      let x = saved?.x ?? 0
      let y = saved?.y ?? 1
      pdf.go(
        to: PDFDestination(
          page: page,
          at: CGPoint(x: bounds.minX + x * bounds.width, y: bounds.minY + y * bounds.height)))
    }
    ready = true
    pdfMoved()
    applyAnnotations()
  }
  private func pdfOutline(_ outline: PDFOutline?, document: PDFKit.PDFDocument, depth: Int = 0)
    -> [ReaderEntry]
  {
    guard let outline else { return [] }
    var rows: [ReaderEntry] = []
    for index in 0..<outline.numberOfChildren {
      if let child = outline.child(at: index) {
        let page: Int?
        if let target = child.destination?.page { page = document.index(for: target) }
        else { page = nil }
        rows.append(ReaderEntry(title: child.label ?? "章节", depth: depth, page: page))
        rows += pdfOutline(child, document: document, depth: depth + 1)
      }
    }
    return rows
  }
  func goPDF(page index: Int) {
    guard let pdf = pdfView, let document = pdf.document,
      let page = document.page(at: max(0, min(document.pageCount - 1, index)))
    else { return }
    pdf.go(to: page)
    pdfMoved()
  }
  private func pdfMoved() {
    guard ready, let session, let pdf = pdfView, let document = pdf.document,
      let page = pdf.currentPage
    else { return }
    let index = document.index(for: page)
    session.currentPage = index + 1
    let bounds = page.bounds(for: .cropBox)
    let point = pdf.currentDestination?.point ?? CGPoint(x: bounds.minX, y: bounds.maxY)
    session.moved(
      to: ReadingPosition(
        page: index, x: Double((point.x - bounds.minX) / max(1, bounds.width)),
        y: Double((point.y - bounds.minY) / max(1, bounds.height))),
      progress: ReadingProgress.pdf(page: index, count: document.pageCount),
      label: "第 \(index+1) / \(document.pageCount) 页")
  }

  // 退出或进入后台时补采同一 PDF 页内的缩放、滚动位置。
  func captureCurrentPosition() {
    if pdfView != nil { pdfMoved() }
    else if let epub, let locator = epub.currentLocation { updateEPUBProgress(epub, locator: locator) }
  }

  // 退出封面预览或阅读加载页时停止解析，不让已关闭的界面继续生成位置列表。
  func cancelLoading() { loadTask?.cancel() }

  // PDF 导出完整原页面；EPUB 使用可见 WKWebView 的快照，避免截入工具栏或得到空白图。
  func currentPageImage() async throws -> UIImage {
    guard ready, let session else { throw LibraryError.message("书页尚未准备好，请稍后再试") }
    if let pdf = pdfView, let page = pdf.currentPage, let document = pdf.document,
      let url = session.model.fileURL(session.book.readingPath)
    {
      let index = document.index(for: page)
      return try await Task.detached(priority: .userInitiated) {
        guard let document = PDFKit.PDFDocument(url: url), let page = document.page(at: index) else {
          throw LibraryError.message("无法读取此 PDF 页面")
        }
        let bounds = page.bounds(for: .cropBox)
        let scale = 1800 / max(1, max(bounds.width, bounds.height))
        return page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .cropBox)
      }.value
    }
    guard let epub, epub.currentLocation != nil else {
      throw LibraryError.message("书页正在排版，请等正文显示后再选择")
    }
    @MainActor func webViews(in view: UIView) -> [WKWebView] {
      if let web = view as? WKWebView { return [web] }
      return view.subviews.flatMap { webViews(in: $0) }
    }
    let visible = webViews(in: epub.view).filter { web in
      !web.isHidden && web.alpha > 0 && web.window != nil
        && web.convert(web.bounds, to: epub.view).intersection(epub.view.bounds).width > 1
    }.sorted { first, second in
      let a = first.convert(first.bounds, to: epub.view).intersection(epub.view.bounds)
      let b = second.convert(second.bounds, to: epub.view).intersection(epub.view.bounds)
      return a.width * a.height > b.width * b.height
    }
    guard let web = visible.first, !web.isLoading else {
      throw LibraryError.message("书页尚未显示完成，请稍后再试")
    }
    let rect = web.convert(epub.view.bounds, from: epub.view).intersection(web.bounds)
    guard !rect.isNull, rect.width > 1, rect.height > 1 else {
      throw LibraryError.message("当前没有可选的书页")
    }
    let config = WKSnapshotConfiguration()
    config.rect = rect
    config.snapshotWidth = NSNumber(value: Double(min(800, rect.width)))
    return try await withCheckedThrowingContinuation { continuation in
      web.takeSnapshot(with: config) { image, error in
        if let image { continuation.resume(returning: image) }
        else { continuation.resume(throwing: error ?? LibraryError.message("无法截取此书页")) }
      }
    }
  }

  // 主题和排版只在偏好实际变化时更新，保持当前定位与选择状态。
  func applyPreferences(_ preferences: ReaderPreferences) {
    let preferences = resolvedPreferences(preferences)
    guard lastPreferences != preferences else { return }
    lastPreferences = preferences
    epub?.submitPreferences(epubPreferences(preferences))
    if let pdf = pdfView {
      let old = pdf.currentDestination
      pdf.displayDirection = preferences.scroll ? .vertical : .horizontal
      pdf.displayMode = preferences.scroll ? .singlePageContinuous : .singlePage
      pdf.usePageViewController(!preferences.scroll, withViewOptions: nil)
      pdf.backgroundColor =
        preferences.theme == .paper
        ? UIColor(red: 0.96, green: 0.93, blue: 0.86, alpha: 1)
        : preferences.theme == .dark ? .black : .secondarySystemBackground
      if let old { pdf.go(to: old) }
    }
  }
  // 封面选择使用浅色分页预览，调整不会改写用户原来的阅读偏好。
  private func resolvedPreferences(_ value: ReaderPreferences) -> ReaderPreferences {
    guard session?.savesProgress == false else { return value }
    var value = value
    value.theme = .light
    value.scroll = false
    return value
  }
  private func epubPreferences(_ value: ReaderPreferences) -> EPUBPreferences {
    EPUBPreferences(
      fontFamily: value.serif ? .serif : .sansSerif, fontSize: value.fontSize / 100 * 1.125,
      lineHeight: value.lineHeight, pageMargins: value.margins,
      paragraphIndent: 2, paragraphSpacing: 0.45, publisherStyles: false,
      scroll: value.scroll, textAlign: .justify,
      theme: value.theme == .paper
        ? .sepia
        : value.theme == .dark
          ? .dark
          : value.theme == .light
            ? .light : traitCollection.userInterfaceStyle == .dark ? .dark : .light)
  }

  // 正常阅读的页眉、页脚已经避开安全区，不再让 Readium 重复添加上下 62 点空白。
  func navigatorContentInset(_ navigator: VisualNavigator) -> UIEdgeInsets? {
    session?.savesProgress == true ? .zero : nil
  }

  // 样式只注入可重排 EPUB；固定版式与 PDF 完整保留原书页内容。
  func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts controller: WKUserContentController) {
    guard session?.publication?.metadata.layout != .fixed,
      let url = Bundle.module.url(forResource: "ReaderLayout", withExtension: "css"),
      let css = try? String(contentsOf: url, encoding: .utf8),
      let data = try? JSONSerialization.data(withJSONObject: [css]),
      let encoded = String(data: data, encoding: .utf8) else { return }
    let script = """
      (() => {
        // 独立样式不包含颜色声明，继续由 Readium 实时应用主题。
        const style = document.createElement('style');
        style.textContent = \(encoded)[0];
        document.head.appendChild(style);
        // 识别已有章标题，包括旧版 TXT 阅读副本的首段标题，不插入或替换文字。
        const first = [...document.querySelectorAll('body h1, body h2, body p, body [role="heading"]')]
          .find(element => element.textContent.trim());
        if (first && (first.matches('h1,h2,[role="heading"]') ||
            first.textContent.trim() === document.title.trim())) {
          first.setAttribute('data-miolib-chapter-title', '');
        }
        // 保留原文自带缩进，使已导入书籍也能直接使用新的版式。
        for (const paragraph of document.querySelectorAll('p')) {
          if (/^[\\u3000]|^[ \\t]{2,}/.test(paragraph.textContent)) {
            paragraph.setAttribute('data-miolib-preindented', '');
          }
        }
      })();
      """
    controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
  }
  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if let session, session.model.preferences.theme == .system {
      lastPreferences = nil
      applyPreferences(session.model.preferences)
    }
  }

  // EPUB 高亮位置由 Readium Locator 恢复，PDF 高亮保存页内原始坐标。
  func applyAnnotations() {
    guard let session, session.savesProgress else { return }
    let notes = session.notes
    if let epub {
      let decorations = notes.filter { $0.kind != .bookmark }.compactMap { note -> Decoration? in
        guard let json = note.position.locatorJSON, let locator = try? Locator(jsonString: json)
        else { return nil }
        return Decoration(
          id: note.id.uuidString, locator: locator, style: .highlight(tint: Self.color(note.color)))
      }
      epub.apply(decorations: decorations, in: "miolib")
    }
    if let document = pdfView?.document {
      let updatedPages=Set(notes.flatMap{note in note.rects.map(\.page) + (note.rects.isEmpty ? [note.position.page].compactMap{$0}:[])})
      for index in annotatedPDFPages.union(updatedPages) {
        guard let page = document.page(at: index) else { continue }
        for annotation in page.annotations where annotation.userName?.hasPrefix("MioLib:") == true {
          page.removeAnnotation(annotation)
        }
      }
      annotatedPDFPages=updatedPages
      for note in notes where note.kind != .bookmark {
        for rect in note.rects {
          guard let page = document.page(at: rect.page) else { continue }
          let annotation = PDFAnnotation(
            bounds: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
            forType: .highlight, withProperties: nil)
          annotation.color = Self.color(note.color).withAlphaComponent(0.4)
          annotation.userName = "MioLib:" + note.id.uuidString
          annotation.contents = note.note
          page.addAnnotation(annotation)
        }
        if note.rects.isEmpty, let index = note.position.page, let page = document.page(at: index) {
          let bounds = page.bounds(for: .cropBox)
          let annotation = PDFAnnotation(
            bounds: CGRect(x: bounds.minX + 18, y: bounds.maxY - 44, width: 24, height: 24),
            forType: .text, withProperties: nil)
          annotation.iconType = .note
          annotation.contents = note.note
          annotation.userName = "MioLib:" + note.id.uuidString
          annotation.color = Self.color(note.color)
          page.addAnnotation(annotation)
        }
      }
    }
  }
  static func color(_ value: String) -> UIColor {
    switch value {
    case "green": .systemGreen
    case "blue": .systemBlue
    case "pink": .systemPink
    default: .systemYellow
    }
  }
  @objc func highlightSelection() { makeSelection(note: false) }
  @objc func annotateSelection() { makeSelection(note: true) }
  private func makeSelection(note: Bool) {
    guard let session else { return }
    let annotation: Annotation
    if let selection = epub?.currentSelection, let json = try? selection.locator.jsonString() {
      annotation = Annotation(
        bookID: session.book.id, kind: .highlight, position: .init(locatorJSON: json),
        quote: selection.locator.text.highlight ?? "",
        chapter: selection.locator.title ?? session.positionLabel)
      epub?.clearSelection()
    } else if let pdf = pdfView, let selection = pdf.currentSelection, let document = pdf.document {
      var rects: [PageRect] = []
      for line in selection.selectionsByLine() {
        for page in line.pages {
          let rect = line.bounds(for: page)
          rects.append(
            PageRect(
              page: document.index(for: page), x: rect.minX, y: rect.minY, width: rect.width,
              height: rect.height))
        }
      }
      guard let first = selection.pages.first else { return }
      annotation = Annotation(
        bookID: session.book.id, kind: .highlight,
        position: .init(page: document.index(for: first)), quote: selection.string ?? "",
        chapter: session.positionLabel, rects: rects)
      pdf.clearSelection()
    } else {
      session.pageNote()
      return
    }
    if note { session.draft = annotation } else { session.save(annotation) }
  }

  // 点击中央显示工具栏；PDF 边缘翻页避开缩放和正在进行的文字选择。
  @objc private func pdfTapped(_ recognizer: UITapGestureRecognizer) {
    guard let pdf = pdfView, pdf.currentSelection == nil, let session else { return }
    let fraction = recognizer.location(in: view).x / max(1, view.bounds.width)
    if fraction > 0.25 && fraction < 0.75 {
      session.controls.toggle()
    } else if !session.model.preferences.scroll, let page = pdf.currentPage,
      let document = pdf.document
    {
      goPDF(page: document.index(for: page) + (fraction < 0.25 ? -1 : 1))
    }
  }
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool { true }
  func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
    guard let epub = navigator as? EPUBNavigatorViewController else { return }
    updateEPUBProgress(epub, locator: locator)
  }
  // Viewport 也会在旋转、滚动及排版改变时更新，末页完成状态不能只依赖页首 Locator。
  func navigator(_ navigator: any ViewportObservingNavigator, viewportDidChange viewport: NavigatorViewport?) {
    guard let epub = navigator as? EPUBNavigatorViewController, let locator = epub.currentLocation else { return }
    updateEPUBProgress(epub, locator: locator)
  }
  private func updateEPUBProgress(_ navigator: EPUBNavigatorViewController, locator: Locator) {
    guard let session, let json = try? locator.jsonString() else { return }
    let visible = navigator.viewport?.resources.last
    // 分页按真实可见范围计算，字号、边距及旋转引发的重新排版会自动刷新。
    session.renderedPage = navigator.viewport?.resources.first.flatMap {
      ReaderRenderedPage(progression: $0.progression)
    }
    let last = session.publication?.readingOrder.last?.url()
    let value = ReadingProgress.text(raw: locator.locations.totalProgression ?? locator.locations.progression ?? 0,
      isLastResource: visible?.href == last && last != nil, visibleResourceEnd: visible?.progression.upperBound)
    // 使用 Readium 的位置序号直接映射跳转，末页按实际可见尾端保持一致。
    let locationPage = locator.locations.position ?? Int(value * Double(max(0, session.pageCount - 1))) + 1
    session.currentPage = value == 1 ? max(1, session.pageCount)
      : ReaderPageNavigation.page(locationPage, count: session.pageCount)
    session.moved(
      to: .init(locatorJSON: json),
      progress: value,
      label: locator.title ?? "正文")
  }
  func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
    session?.error = error.localizedDescription
  }
  func navigator(_ navigator: Navigator, presentExternalURL url: URL) {
    let alert = UIAlertController(title: "打开外部链接？", message: url.host, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "打开", style: .default) { _ in UIApplication.shared.open(url) })
    present(alert, animated: true)
  }
}

// PDF 选择菜单添加原生响应链动作，系统复制与词典选项继续正常工作。
final class MioPDFView: PDFView {
  weak var owner: ReaderHostController?
  override func buildMenu(with builder: UIMenuBuilder) {
    super.buildMenu(with: builder)
    guard owner != nil else { return }
    let highlight = UIAction(title: "高亮", image: UIImage(systemName: "highlighter")) {
      [weak self] _ in self?.owner?.highlightSelection()
    }
    let note = UIAction(title: "批注", image: UIImage(systemName: "square.and.pencil")) {
      [weak self] _ in self?.owner?.annotateSelection()
    }
    builder.insertChild(
      UIMenu(title: "", options: .displayInline, children: [highlight, note]),
      atStartOfMenu: .standardEdit)
  }
}
