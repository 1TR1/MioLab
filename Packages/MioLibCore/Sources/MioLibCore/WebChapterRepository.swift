import Foundation

extension LibraryRepository {
  // 旧版单页缓存只更新导航元数据，不重新生成正文，保留已经保存的高亮和书签。
  public func updateWebChapterNavigation(bookID: UUID, source: URL, chapterURL: URL,
    navigation: WebChapterNavigation, expectedOriginalPath: String? = nil) throws -> Book
  {
    try writable()
    try navigation.validate()
    var value = try book(bookID)
    guard value.deletedAt == nil, value.webURL == source,
      expectedOriginalPath == nil || value.originalPath == expectedOriginalPath,
      let index = value.cachedWebChapters.firstIndex(where: { WebChapterAddress.identity($0.url) == WebChapterAddress.identity(chapterURL) }) else {
      throw LibraryError.message("网页书籍或章节已改变，请重新打开")
    }
    var chapters = value.cachedWebChapters
    chapters[index].navigation = navigation
    value.webChapters = chapters
    try putBook(value)
    return value
  }

  // 已缓存章节直接定位；当前位置使用 Readium 资源路径，不重置或删掉其他章节的笔记。
  public func selectWebChapter(bookID: UUID, source: URL, chapterURL: URL) throws -> Book {
    try writable()
    let chapterURL = try WebChapterAddress.url(chapterURL)
    var value = try book(bookID)
    guard value.deletedAt == nil, value.webURL == source,
      let index = value.cachedWebChapters.firstIndex(where: { WebChapterAddress.identity($0.url) == WebChapterAddress.identity(chapterURL) }) else {
      throw LibraryError.message("未找到已缓存的章节")
    }
    value.position = value.cachedWebChapters[index].startPosition
    value.progress = Double(index) / Double(max(1, value.cachedWebChapters.count))
    value.lastOpenedAt = Date()
    try putBook(value)
    return value
  }

  // 手动切章沿用同一下载与合并流程，最后由显式选章更新阅读位置。
  public func appendWebChapter(bookID: UUID, source: URL, chapterURL: URL, article: WebArticle,
    images: [WebArticleImage] = []) async throws -> Book
  {
    let original = try book(bookID)
    guard original.webURL == source else { throw LibraryError.message("网页书籍或来源已改变") }
    _ = try await stageWebChapter(for: original, chapterURL: chapterURL, article: article, images: images)
    _ = try await publishWebChapters(for: original, directory: original.webVolumes?.flatMap(\.chapterURLs) ?? [])
    return try selectWebChapter(bookID: bookID, source: source, chapterURL: chapterURL)
  }

  // 每章先单独落盘，再记入待合并清单。自动下载不更改进度、最近阅读或当前阅读副本。
  @discardableResult public func stageWebChapter(for original: Book, chapterURL: URL, article: WebArticle,
    images: [WebArticleImage] = []) async throws -> Book
  {
    try writable()
    try Task.checkCancellation()
    let current = try currentWebBook(matching: original)
    let chapterURL = try WebChapterAddress.url(chapterURL)
    let key = WebChapterAddress.identity(chapterURL)
    if current.downloadedWebChapters.contains(where: { WebChapterAddress.identity($0.url) == key }) { return current }
    guard current.allowsWebCaching(at: chapterURL) else { throw LibraryError.message("本章所在卷未选择缓存") }
    try article.navigation?.validate()
    guard current.hasWebReadingCopy, current.downloadedWebChapters.count < 2000 else {
      throw LibraryError.message("缓存章节数量超出限制，或没有可用的首章")
    }
    guard article.navigation?.isContents != true else { throw LibraryError.message("此链接是目录，无法缓存为正文") }
    let chapterPath = "Reading/\(UUID().uuidString).epub"
    let chapterFile = try paths.url(chapterPath)
    do {
      try await WebArticleConverter.convert(article, images: images, source: chapterURL,
        title: article.title.isEmpty ? current.title : article.title, destination: chapterFile)
      try Task.checkCancellation()
      try writable()
      var latest = try currentWebBook(matching: original)
      if latest.downloadedWebChapters.contains(where: { WebChapterAddress.identity($0.url) == key }) {
        try? FileManager.default.removeItem(at: chapterFile)
        return latest
      }
      let chapter = WebBookChapter(url: chapterURL, title: article.title.isEmpty ? "新章节" : article.title,
        readingPath: chapterPath, resourcePrefix: latest.webResourcePrefix(for: chapterURL, isFirst: false),
        navigation: article.navigation)
      // 在提交前检查所有源副本的体积，防止下载中断时占用过多空间。
      let downloaded = latest.downloadedWebChapters + [chapter]
      let size = try downloaded.reduce(into: Int64(0)) { total, item in
        let file = try paths.url(item.readingPath)
        total += Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
      }
      guard downloaded.count <= 2000, size <= 512 * 1024 * 1024 else {
        throw LibraryError.message("缓存超过 2,000 章或 512 MB")
      }
      latest.webPendingChapters = (latest.webPendingChapters ?? []) + [chapter]
      latest.restoreWebChapterPrefix(for: chapterURL)
      latest.webCacheCompleted = nil
      try putBook(latest)
      return latest
    } catch {
      try? FileManager.default.removeItem(at: chapterFile)
      throw error
    }
  }

  // 一批章节只生成一次聚合 EPUB。若在写包过程中又下载了新章，留给下一次合并。
  @discardableResult public func publishWebChapters(for original: Book, directory: [URL] = [],
    completesBook: Bool = false) async throws -> Book
  {
    try writable()
    try Task.checkCancellation()
    let snapshot = try currentWebBook(matching: original)
    guard snapshot.hasWebReadingCopy else { return snapshot }
    // 聚合书脊沿用全书顺序。完成判断只检查本次请求的章节，后补的卷不会排到旧卷之前。
    let catalog = snapshot.webVolumes?.flatMap(\.chapterURLs) ?? []
    let chapters = orderedWebChapters(snapshot, directory: catalog.isEmpty ? directory : catalog)
    let downloadedURLs = Set(chapters.map { WebChapterAddress.identity($0.url) })
    guard !completesBook || Set(directory.map(WebChapterAddress.identity)).isSubset(of: downloadedURLs) else {
      throw LibraryError.message("仍有章节未下载，不能标记为离线完成")
    }
    if chapters == snapshot.cachedWebChapters, snapshot.webPendingChapters == nil {
      guard completesBook, snapshot.webCacheCompleted != true else { return snapshot }
      var completed = snapshot
      completed.webCacheCompleted = true
      try putBook(completed)
      return completed
    }
    let combinedPath = "Reading/\(UUID().uuidString).epub"
    let combinedFile = try paths.url(combinedPath)
    do {
      try await WebBookAssembler.combine(chapters, paths: paths, title: snapshot.title, destination: combinedFile)
      try Task.checkCancellation()
      try writable()
      var latest = try currentWebBook(matching: original)
      guard latest.readingPath == snapshot.readingPath,
        latest.cachedWebChapters == snapshot.cachedWebChapters else {
        throw LibraryError.message("章节目录已更新，请重试")
      }
      let mergedURLs = Set(chapters.map(\.url))
      let remaining = (latest.webPendingChapters ?? []).filter { !mergedURLs.contains($0.url) }
      latest.webChapters = chapters
      latest.webPendingChapters = remaining.isEmpty ? nil : remaining
      latest.readingPath = combinedPath
      latest.webSnapshotDate = Date()
      latest.webCacheCompleted = completesBook && remaining.isEmpty ? true : nil
      // 已有定位直接沿用。首次从中间章节进入且尚无进度时，也从最初打开的正文开始。
      if latest.position == nil, let first = snapshot.cachedWebChapters.first, first.navigation?.isContents != true {
        latest.position = first.startPosition
      }
      try putBook(latest)
      removeUnusedWebAssets([snapshot.readingPath])
      return latest
    } catch {
      try? FileManager.default.removeItem(at: combinedFile)
      throw error
    }
  }

  // 改链、恢复、删卷或更换缓存选择后，正在写入的旧任务不能覆盖新状态。
  func currentWebBook(matching original: Book) throws -> Book {
    let value = try book(original.id)
    guard value.deletedAt == nil, value.format == .web, value.webURL == original.webURL,
      value.originalPath == original.originalPath, value.webCacheRevision == original.webCacheRevision else {
      throw LibraryError.message("网页书籍或缓存选择已改变，请重新操作")
    }
    return value
  }

  // 目录顺序优先，未列入目录的历史章节仍保留；没有目录时按相邻链接安放新章。
  private func orderedWebChapters(_ book: Book, directory: [URL]) -> [WebBookChapter] {
    if !directory.isEmpty {
      // 旧缓存可能用了不同子域。每个章号先占一个有序位置，其余历史资源仍原样保留。
      var remaining = Dictionary(grouping: book.downloadedWebChapters) { WebChapterAddress.identity($0.url) }
      let ordered = directory.flatMap { remaining.removeValue(forKey: WebChapterAddress.identity($0)) ?? [] }
      return ordered + book.downloadedWebChapters.filter { remaining[WebChapterAddress.identity($0.url)] != nil }
    }
    var ordered = book.cachedWebChapters
    for chapter in book.webPendingChapters ?? [] {
      if let next = chapter.navigation?.nextURL, let index = ordered.firstIndex(where: { $0.url == next }) {
        ordered.insert(chapter, at: index)
      } else if let previous = chapter.navigation?.previousURL, let index = ordered.firstIndex(where: { $0.url == previous }) {
        ordered.insert(chapter, at: index + 1)
      } else { ordered.append(chapter) }
    }
    return ordered
  }
}
