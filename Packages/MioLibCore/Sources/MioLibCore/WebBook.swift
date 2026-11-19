import Foundation

// 网页书籍仍使用普通书籍表、稳定 ID、封面、书架和标注，只增加来源链接。
extension LibraryRepository {
  // 只更改指定书目的开关，读取最新书目，保留同时更新的阅读进度和章节缓存。
  public func setWebReaderEnabled(_ enabled: Bool, for original: Book) throws {
    try writable()
    var value = try book(original.id)
    guard value.format == .web, value.deletedAt == nil, value.originalPath == original.originalPath else {
      throw LibraryError.message("网页书籍已改变，请重新打开")
    }
    guard value.webReaderEnabled != enabled else { return }
    value.webReaderEnabled = enabled
    try putBook(value)
  }

  // 原网页模式同样计入最近阅读，读取最新记录以保留已保存的进度和笔记。
  public func markWebBookOpened(_ id: UUID, source: URL) throws {
    try writable()
    var value = try book(id)
    guard value.deletedAt == nil, value.format == .web, value.webURL == source else { return }
    value.lastOpenedAt = Date()
    try putBook(value)
  }

  // 重复导出返回已有书籍，软删除书籍可恢复；收藏本身独立保留。
  @discardableResult public func exportWebBookmarkToShelf(_ id: UUID, folderID: UUID? = nil,
    volumes: [WebBookVolume]? = nil, selectedVolumes: Set<String>? = nil) throws -> Book
  {
    try writable()
    guard let bookmark = try webBookmarks().first(where: { $0.id == id }) else {
      throw LibraryError.message("此收藏已被删除")
    }
    if let folderID, !(try folders()).contains(where: { $0.id == folderID }) {
      throw LibraryError.message("目标书架已被删除，请重新选择")
    }
    let fingerprint = Self.webFingerprint(bookmark.url)
    if var existing = try existingBook(fingerprint: fingerprint) {
      if existing.deletedAt != nil {
        existing.deletedAt = nil
        existing.folderID = folderID
        try putBook(existing)
      }
      return existing
    }
    // 未识别目录时可以先缓存整本，也可以只保存链接，之后再到设置中选卷。
    if let volumes { try WebBookVolume.validateCatalog(volumes) }
    let available = Set((volumes ?? [.wholeBook]).map(\.id))
    guard selectedVolumes.map({ $0.isSubset(of: available) }) ?? true else {
      throw LibraryError.message("所选卷不在当前目录中，请重新选择")
    }
    let original = try storeWebLink(bookmark.url)
    var value = Book(title: bookmark.title, author: bookmark.url.host ?? "", format: .web,
      originalPath: original, readingPath: original, fingerprint: fingerprint, folderID: folderID)
    value.webURL = bookmark.url
    value.webVolumes = volumes
    value.webVolumeIDs = selectedVolumes.map { selection in (volumes ?? [.wholeBook]).map(\.id).filter(selection.contains) }
    do { try insert(value) }
    catch {
      try? FileManager.default.removeItem(at: paths.url(original))
      throw error
    }
    return value
  }

  // 提取后才生成 EPUB；等待 ZIP 写入期间的删除、改链、恢复或重复提取不会被旧任务覆盖。
  public func saveWebReadingCopy(bookID: UUID, source: URL, article: WebArticle,
    images: [WebArticleImage] = [], expectedOriginalPath: String? = nil) async throws -> Book
  {
    try writable()
    let original = try book(bookID)
    guard original.deletedAt == nil, original.format == .web, original.webURL == source,
      expectedOriginalPath == nil || original.originalPath == expectedOriginalPath else {
      throw LibraryError.message("网页书籍已被删除或来源无效")
    }
    if original.hasWebReadingCopy { return original }
    try article.navigation?.validate()
    let chapterURL = try WebChapterAddress.url(article.pageURL ?? source)
    guard original.allowsWebCaching(at: chapterURL) else { throw LibraryError.message("本章所在卷未选择缓存") }
    let relative = "Reading/\(UUID().uuidString).epub"
    let destination = try paths.url(relative)
    let chapter = WebBookChapter(url: chapterURL, title: article.title.isEmpty ? original.title : article.title,
      readingPath: relative, resourcePrefix: original.webResourcePrefix(for: chapterURL, isFirst: true),
      navigation: article.navigation)
    // 重新下载删过的章时，首章也可能需要其原有前缀来恢复笔记位置。
    let readingPath = chapter.resourcePrefix.isEmpty ? relative : "Reading/\(UUID().uuidString).epub"
    let readingFile = try paths.url(readingPath)
    do {
      try await WebArticleConverter.convert(article, images: images, source: chapterURL,
        title: original.title, destination: destination)
      if readingPath != relative {
        try await WebBookAssembler.combine([chapter], paths: paths, title: original.title, destination: readingFile)
      }
      try Task.checkCancellation()
      try writable()
      var current = try currentWebBook(matching: original)
      if current.hasWebReadingCopy {
        try? FileManager.default.removeItem(at: destination)
        if readingPath != relative { try? FileManager.default.removeItem(at: readingFile) }
        return current
      }
      current.readingPath = readingPath
      current.webSnapshotDate = Date()
      current.webChapters = [chapter]
      current.restoreWebChapterPrefix(for: chapterURL)
      try putBook(current)
      return current
    } catch {
      try? FileManager.default.removeItem(at: destination)
      if readingPath != relative { try? FileManager.default.removeItem(at: readingFile) }
      throw error
    }
  }

  // 描述文件使用新路径写入，数据库提交失败时不会破坏旧链接或旧备份引用。
  func storeWebLink(_ url: URL) throws -> String {
    let relative = "Originals/\(UUID().uuidString).web.json"
    try LibraryJSON.encode(["url": url.absoluteString]).write(to: paths.url(relative), options: .atomic)
    return relative
  }

  // 与文件内容摘要分开命名，避免网页地址与普通文件产生偶然去重。
  static func webFingerprint(_ url: URL) -> String {
    FileFingerprint.hash(Data("MioLib web book: \(url.absoluteString)".utf8))
  }

  // 读取引用失败时跳过清理，绝不因回收失败撤销已经提交的链接修改。
  func removeUnusedWebAssets(_ candidates: Set<String>) {
    guard let allBooks = try? books(includeDeleted: true), let allFolders = try? folders(),
      let preferences = try? preferences() else { return }
    var references = Set(allBooks.flatMap(\.assetPaths))
    references.formUnion(allFolders.compactMap(\.coverPath))
    if let avatar = preferences.profileAvatarPath { references.insert(avatar) }
    for relative in candidates.subtracting(references) {
      if activeWebReadingPaths[relative] != nil { retiredWebReadingPaths.insert(relative) }
      else if let url = try? paths.url(relative) { try? FileManager.default.removeItem(at: url) }
    }
  }

  // 阅读器打开包前取得持有权，合并期间继续使用同一文件和原来的页内位置。
  public func retainWebReadingPath(_ relative: String) -> Bool {
    guard let url = try? paths.url(relative), FileManager.default.fileExists(atPath: url.path) else { return false }
    activeWebReadingPaths[relative, default: 0] += 1
    return true
  }

  // 最后一个阅读器关闭时，才重查引用并回收已经被替换的文件。
  public func releaseWebReadingPath(_ relative: String) {
    guard let count = activeWebReadingPaths[relative] else { return }
    if count > 1 { activeWebReadingPaths[relative] = count - 1 }
    else {
      activeWebReadingPaths[relative] = nil
      if retiredWebReadingPaths.remove(relative) != nil { removeUnusedWebAssets([relative]) }
    }
  }
}
