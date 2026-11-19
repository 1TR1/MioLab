import MioLibCore
import SwiftUI

// 只响应当前用户的切章操作；已缓存章节直接定位，新章节通过独立 WebKit 会话按需读取。
@MainActor final class WebReaderNavigation: ObservableObject {
  let model: AppModel
  var returnURL: URL?
  init(model: AppModel) { self.model = model }

  // 先读取卷目录，再开始离线下载，保存的链接指向未选卷时从所选卷开始阅读。
  func cacheBook(_ original: Book, report: (Book, [URL]) -> Void) async throws -> Book {
    guard let repository = model.repository else { throw LibraryError.message("书库尚未就绪") }
    var book = try await repository.book(original.id)
    guard let source = original.webURL, book.deletedAt == nil, book.webURL == source,
      book.originalPath == original.originalPath else {
      throw LibraryError.message("网页书籍或来源已改变")
    }
    report(book, [])
    if !book.hasWebCacheSelection || book.webCacheCompleted == true { return book }

    // 批量任务复用一个 WebKit 会话，沿用当前设备的网站登录和字符编码。
    // 首章自动加载使用较短超时，完全无响应的站点也有时间在失败窗口内重试。
    let browser = try await makeBrowser(pageLoadTimeout: book.hasWebReadingCopy ? .seconds(25) : .seconds(9))
    defer { browser.close() }
    if Self.hasVolumeDirectory(at: source), book.webVolumes == nil {
      let volumes = try await loadVolumes(at: source, in: browser)
      book = try await repository.recordWebVolumes(volumes, for: book)
    }
    if let volumes = book.webVolumes, volumes != [.wholeBook] {
      return try await cacheVolumes(volumes, in: book, source: source, browser: browser, repository: repository, report: report)
    }
    let entry = try await cacheEntry(for: book, source: source, in: browser, repository: repository)
    book = entry.book
    var directory = entry.directory
    report(book, directory)

    guard directory.count <= 2000 else { throw LibraryError.message("目录超过 2,000 章") }
    if !directory.isEmpty {
      for url in directory {
        if book.downloadedWebChapters.contains(where: { $0.url == url }) { continue }
        book = try await downloadChapter(url, book: book, browser: browser, repository: repository)
        report(book, directory)
      }
    } else {
      // 没有目录的站点从打开的章节向前、向后沿实际链接遍历，记录访问过的地址停止环路。
      var visited: Set<URL> = [entry.chapter.url]
      var earlier: [URL] = []
      var later: [URL] = []
      for direction: WebChapterDirection in [.previous, .next] {
        var chapter = entry.chapter
        while let url = try adjacentURL(chapter.navigation, direction: direction), visited.insert(url).inserted {
          try Task.checkCancellation()
          if let saved = book.downloadedWebChapters.first(where: { $0.url == url }) {
            chapter = saved
            if saved.navigation == nil {
              try await browser.loadPage(url)
              let navigation = try await WebArticleCapture.navigation(from: browser.webView)
              book = try await repository.updateWebChapterNavigation(bookID: book.id, source: source,
                chapterURL: url, navigation: navigation, expectedOriginalPath: book.originalPath)
              chapter.navigation = navigation
            }
          } else {
            book = try await downloadChapter(url, book: book, browser: browser, repository: repository)
            guard let saved = book.downloadedWebChapters.first(where: { $0.url == url }) else {
              throw LibraryError.message("章节保存未完成")
            }
            chapter = saved
            report(book, [])
          }
          if direction == .previous { earlier.append(url) }
          else { later.append(url) }
        }
      }
      // 有些站点只有单向链接，按遍历所得顺序合并，仍能把先前章节排在种子章之前。
      directory = Array(earlier.reversed()) + [entry.chapter.url] + later
    }
    return try await repository.publishWebChapters(for: book, directory: directory, completesBook: true)
  }

  // 导出和设置只访问卷目录，不读取正文或下载图片；普通网站用整本这一单位。
  func loadVolumes(at source: URL) async throws -> [WebBookVolume] {
    guard Self.hasVolumeDirectory(at: source) else { return [.wholeBook] }
    let browser = try await makeBrowser(pageLoadTimeout: .seconds(9))
    defer { browser.close() }
    return try await loadVolumes(at: source, in: browser)
  }

  // 文库的书籍详情、目录和正文都支持分卷，其他普通网页可以按整本保存。
  static func hasVolumeDirectory(at url: URL) -> Bool {
    WebChapterAddress.isWenku8(url) &&
      url.path.range(of: "^/(book/\\d+|novel/\\d+/\\d+/(index|\\d+))\\.htm$", options: .regularExpression) != nil
  }

  private func loadVolumes(at source: URL, in browser: WebBrowserSession) async throws -> [WebBookVolume] {
    // 章页和目录在同一目录，可以直接访问目录，详情页按站点提供的链接进入。
    var target = source
    if source.path.range(of: "^/novel/\\d+/\\d+/\\d+\\.htm$", options: .regularExpression) != nil {
      var address = URLComponents(url: source, resolvingAgainstBaseURL: false)
      address?.path = source.deletingLastPathComponent().path + "/index.htm"
      address?.query = nil
      address?.fragment = nil
      target = address?.url ?? source
    }
    try await browser.loadPage(target)
    var navigation = try await WebArticleCapture.navigation(from: browser.webView)
    if navigation.volumes == nil, let contents = navigation.contentsURL {
      try await browser.loadPage(contents)
      navigation = try await WebArticleCapture.navigation(from: browser.webView)
    }
    guard navigation.isContents, let volumes = navigation.volumes, !volumes.isEmpty else {
      throw LibraryError.message("未找到卷目录，请在原网页检查此链接")
    }
    try WebBookVolume.validateCatalog(volumes)
    return volumes
  }

  // 每完成一卷就更新可读副本。一卷遇到坏链接时，继续尝试其它已选卷。
  private func cacheVolumes(_ volumes: [WebBookVolume], in original: Book, source: URL,
    browser: WebBrowserSession, repository: LibraryRepository, report: (Book, [URL]) -> Void) async throws -> Book
  {
    var book = original
    var selected = volumes.filter(book.wantsWebVolume)
    let directory = selected.flatMap(\.chapterURLs)
    let sourceKey = WebChapterAddress.identity(source)
    var downloaded = Set(book.downloadedWebChapters.map { WebChapterAddress.identity($0.url) })
    var failure: Error?
    report(book, directory)

    // 首次打开已选卷中的一个章时优先取该章，合并时仍按卷和目录的原始顺序排列。
    if !book.hasWebReadingCopy, let index = selected.firstIndex(where: { volume in
      volume.chapterURLs.contains { WebChapterAddress.identity($0) == sourceKey }
    }) {
      let first = selected.remove(at: index)
      selected.insert(first, at: 0)
    }
    for volume in selected {
      let urls = volume.chapterURLs
      let start = book.hasWebReadingCopy ? nil : urls.first { WebChapterAddress.identity($0) == sourceKey }
      for url in [start].compactMap({ $0 }) + urls.filter({ $0 != start }) {
        try Task.checkCancellation()
        let key = WebChapterAddress.identity(url)
        if downloaded.contains(key) { continue }
        do {
          book = try await downloadChapter(url, book: book, browser: browser, repository: repository)
          downloaded.insert(key)
          report(book, directory)
        } catch is CancellationError { throw CancellationError() }
        catch { failure = failure ?? error; break }
      }
      if book.webPendingChapters != nil {
        book = try await repository.publishWebChapters(for: book, directory: directory)
        report(book, directory)
      }
    }
    if let failure { throw failure }
    return try await repository.publishWebChapters(for: book, directory: directory, completesBook: true)
  }

  // 目录来源支持书籍详情、目录和章页。已有正文只补导航，不替换其内容或定位。
  private func cacheEntry(for book: Book, source: URL, in browser: WebBrowserSession,
    repository: LibraryRepository) async throws -> (book: Book, chapter: WebBookChapter, directory: [URL])
  {
    var book = book
    let cached = book.cachedWebChapters.first(where: { $0.navigation?.isContents != true })
    if let cached, cached.navigation != nil { return (book, cached, []) }
    let target = cached?.url ?? source
    try await browser.loadPage(target)
    var navigation = try await WebArticleCapture.navigation(from: browser.webView)

    // 迁移已有缓存，包括旧版本曾把目录保存为正文的情况。
    if let cached {
      book = try await repository.updateWebChapterNavigation(bookID: book.id, source: source,
        chapterURL: cached.url, navigation: navigation, expectedOriginalPath: book.originalPath)
      if !navigation.isContents, let chapter = book.cachedWebChapters.first(where: { $0.url == cached.url }) {
        return (book, chapter, [])
      }
    }

    // 详情页先跳到同一本书的目录，再按目录第一项开始。
    var chapterURL = browser.url ?? target
    var directory: [URL] = []
    if navigation.isContents {
      if let contents = navigation.contentsURL, navigation.firstChapterURL == nil {
        try await browser.loadPage(contents)
        navigation = try await WebArticleCapture.navigation(from: browser.webView)
      }
      directory = try orderedDirectory(navigation)
      guard let first = directory.first ?? navigation.firstChapterURL else {
        throw LibraryError.message("未找到首章，请先在原网页打开章节目录")
      }
      chapterURL = try WebChapterAddress.url(first)
      try await loadChapterPage(chapterURL, in: browser)
    }
    let captured = try await captureLoadedChapter(in: browser)
    if book.hasWebReadingCopy {
      book = try await repository.stageWebChapter(for: book, chapterURL: chapterURL,
        article: captured.article, images: captured.images)
      book = try await repository.publishWebChapters(for: book, directory: directory)
    } else {
      book = try await repository.saveWebReadingCopy(bookID: book.id, source: source,
        article: captured.article, images: captured.images, expectedOriginalPath: book.originalPath)
    }
    guard let chapter = book.cachedWebChapters.first(where: { $0.navigation?.isContents != true }) else {
      throw LibraryError.message("未找到可阅读的首章")
    }
    return (book, chapter, directory)
  }

  // 每次只等待一个页面并核对跳转目标，登录或错误重定向不会覆盖已缓存的章节。
  private func downloadChapter(_ url: URL, book: Book, browser: WebBrowserSession,
    repository: LibraryRepository) async throws -> Book
  {
    try await Task.sleep(for: .milliseconds(180))
    try await loadChapterPage(url, in: browser)
    let captured = try await captureLoadedChapter(in: browser)
    // 首个已选章节可立即打开，随后落盘的章节按卷批量合并。
    if !book.hasWebReadingCopy, let source = book.webURL {
      return try await repository.saveWebReadingCopy(bookID: book.id, source: source,
        article: captured.article, images: captured.images, expectedOriginalPath: book.originalPath)
    }
    return try await repository.stageWebChapter(for: book, chapterURL: url, article: captured.article, images: captured.images)
  }

  // 目录原样保序，并在一般跳章和整本缓存中统一去除页内锚点。
  private func orderedDirectory(_ navigation: WebChapterNavigation) throws -> [URL] {
    var seen: Set<URL> = []
    return try (navigation.chapterURLs ?? []).map(WebChapterAddress.url).filter { seen.insert($0).inserted }
  }

  // 只读取站点给出的相邻地址，对于页内锚点统一使用所在正文页。
  private func adjacentURL(_ navigation: WebChapterNavigation?, direction: WebChapterDirection) throws -> URL? {
    let url = direction == .next ? navigation?.nextURL : navigation?.previousURL
    return try url.map(WebChapterAddress.url)
  }

  // 从当前资源识别所在章，已下载的章节在离线时也能立即合并后切入。
  func changeChapter(bookID: UUID, href: String?, direction: WebChapterDirection) async throws -> Book {
    guard let repository = model.repository else { throw LibraryError.message("书库尚未就绪") }
    var book = try await repository.book(bookID)
    try Task.checkCancellation()
    guard let source = book.webURL, var chapter = book.webChapter(href: href) else {
      throw LibraryError.message("当前书籍没有可切换的网页章节")
    }
    returnURL = chapter.url
    // 部分卷离线时仍按完整目录判断上一章和下一章，避免直接跳过未选卷。
    let directory = book.webVolumes?.flatMap(\.chapterURLs) ?? []
    if let index = directory.firstIndex(where: { WebChapterAddress.identity($0) == WebChapterAddress.identity(chapter.url) }) {
      let adjacent = index + (direction == .next ? 1 : -1)
      if directory.indices.contains(adjacent) {
        return try await openChapter(directory[adjacent], in: book, source: source, repository: repository)
      }
    } else if book.webCacheCompleted == true, directory.isEmpty {
      let chapters = book.cachedWebChapters.filter { $0.navigation?.isContents != true }
      if let index = chapters.firstIndex(where: { $0.url == chapter.url }) {
        let next = index + (direction == .next ? 1 : -1)
        if chapters.indices.contains(next) {
          returnURL = chapters[next].url
          return try await repository.selectWebChapter(bookID: bookID, source: source, chapterURL: chapters[next].url)
        }
      }
    }
    // 缓存末章后站点可能更新，用户再次点击下一章时重新识别导航，不覆盖原正文。
    let needsNavigation = chapter.navigation == nil || (direction == .next
      ? (chapter.navigation?.nextURL == nil && chapter.navigation?.firstChapterURL == nil)
      : chapter.navigation?.previousURL == nil)
    if needsNavigation {
      let navigation = try await navigation(at: chapter.url)
      book = try await repository.updateWebChapterNavigation(bookID: book.id, source: source,
        chapterURL: chapter.url, navigation: navigation, expectedOriginalPath: book.originalPath)
      chapter = book.webChapter(href: href) ?? chapter
    }
    let target = direction == .next
      ? (chapter.navigation?.isContents == true ? chapter.navigation?.firstChapterURL : chapter.navigation?.nextURL)
      : chapter.navigation?.previousURL
    guard let target, target != chapter.url else {
      throw LibraryError.message(direction == .next ? "未找到下一章，可能已经到达末章。可在原网页查看目录。" : "未找到上一章，可能已经到达首章。可在原网页查看目录。")
    }
    return try await openChapter(target, in: book, source: source, repository: repository)
  }

  // 离线已有的章直接读，未选卷在原网页打开或在设置中加入缓存。
  private func openChapter(_ target: URL, in original: Book, source: URL, repository: LibraryRepository) async throws -> Book {
    let bookID = original.id
    var book = original
    let targetURL = try WebChapterAddress.url(target)
    returnURL = targetURL
    try Task.checkCancellation()
    let key = WebChapterAddress.identity(targetURL)
    if book.cachedWebChapters.contains(where: { WebChapterAddress.identity($0.url) == key }) {
      return try await repository.selectWebChapter(bookID: bookID, source: source, chapterURL: targetURL)
    }
    // 换过下载选择后，之前已经落盘的章仍可离线合并、阅读。
    guard book.downloadedWebChapters.contains(where: { WebChapterAddress.identity($0.url) == key })
      || book.allowsWebCaching(at: targetURL) else {
      throw LibraryError.message("目标章节所在卷未缓存。可在原网页继续阅读，或到「我的 → 网页书籍缓存」选择这一卷。")
    }
    // 切换未合并章时暂让手动阅读优先，结束后再继续下载其余章节。
    let resume = await model.webBookCache.pauseAndWait(bookID)
    defer { if resume { model.webBookCache.start(book) } }
    book = try await repository.book(bookID)
    try Task.checkCancellation()
    if book.downloadedWebChapters.contains(where: { WebChapterAddress.identity($0.url) == key }) {
      _ = try await repository.publishWebChapters(for: book, directory: book.webVolumes?.flatMap(\.chapterURLs) ?? [])
      return try await repository.selectWebChapter(bookID: bookID, source: source, chapterURL: targetURL)
    }
    let captured = try await capture(at: targetURL)
    return try await repository.appendWebChapter(bookID: bookID, source: source, chapterURL: targetURL,
      article: captured.article, images: captured.images)
  }

  // 目录识别仅访问用户当前章；WebKit 共享网站数据，不手动抄写 Cookie 或密码。
  private func navigation(at url: URL) async throws -> WebChapterNavigation {
    let browser = try await makeBrowser()
    defer { browser.close() }
    try await browser.loadPage(url)
    return try await WebArticleCapture.navigation(from: browser.webView)
  }

  // 每次只提取一个正文页；目录、错误页和网络失败不替换正在阅读的章节。
  private func capture(at url: URL) async throws -> (article: WebArticle, images: [WebArticleImage]) {
    let browser = try await makeBrowser()
    defer { browser.close() }
    try await loadChapterPage(url, in: browser)
    return try await captureLoadedChapter(in: browser)
  }

  // 章节加载完成才读取 DOM 和图片。目录与错误页不能作为正文保存。
  private func captureLoadedChapter(in browser: WebBrowserSession) async throws -> (article: WebArticle, images: [WebArticleImage]) {
    let article = try await WebArticleCapture.article(from: browser.webView)
    guard article.navigation?.isContents != true else { throw LibraryError.message("此链接返回目录，请在原网页选择正文") }
    let images = try await WebArticleCapture.images(for: article)
    try Task.checkCancellation()
    return (article, images)
  }

  // 校验具体章路径与查询，允许 HTTP 升级和文库域名的 www 变化。
  private func loadChapterPage(_ target: URL, in browser: WebBrowserSession) async throws {
    try await browser.loadPage(target)
    guard let final = browser.url, final.path == target.path, final.query == target.query,
      (final.host == target.host || (WebChapterAddress.isWenku8(final) && WebChapterAddress.isWenku8(target))) else {
      throw LibraryError.message("章节跳转到其他页面，请在原网页检查登录或网站提示")
    }
  }

  // 独立的阅读会话沿用广告过滤偏好，释放后原网页浏览历史不受影响。
  private func makeBrowser(pageLoadTimeout: Duration = .seconds(25)) async throws -> WebBrowserSession {
    let browser = WebBrowserSession(initialURL: nil, loadsReadingCopies: true, pageLoadTimeout: pageLoadTimeout)
    try await browser.configureFiltering(model.webPreferences.blocksAds)
    try Task.checkCancellation()
    return browser
  }

}
