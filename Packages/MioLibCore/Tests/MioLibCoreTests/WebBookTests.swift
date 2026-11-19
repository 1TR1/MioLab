import Foundation
import MioZIPFoundation
import XCTest
@testable import MioLibCore
#if canImport(FoundationXML)
  import FoundationXML
#endif

// 覆盖真实 SQLite、EPUB ZIP 和备份路径，不访问用户的书库或外部网站。
final class WebBookTests: XCTestCase {
  private let article = WebArticle(title: "标题 <与> 阅读", byline: "作者 & 编者", blocks: [
    .init(.heading, text: "第一节", level: 2),
    .init(.paragraph, text: "正文 <script>alert('x')</script> & \"引文\"\u{1}。\n下一行。"),
    .init(.quote, text: "引用内容"), .init(.listItem, text: "1. 列表内容"),
    .init(.code, text: "if (x < 2) {\n  return x;\n}"),
    .init(.image, text: "图示", url: URL(string: "https://example.com/image.png")!),
  ])

  // 去重、收藏独立性、普通书籍操作、封面和数据库重开一起验证。
  func testExportAndOrdinaryBookManagement() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try LibraryRepository(root: root)
    let folder = LibraryFolder(title: "网页书架")
    try await repository.saveFolder(folder)
    let bookmark = try await repository.saveWebBookmark(address: "EXAMPLE.com/article#one", title: "收藏标题")
    let book = try await repository.exportWebBookmarkToShelf(bookmark.id, folderID: folder.id)
    XCTAssertEqual(book.format, .web)
    XCTAssertEqual(book.webURL, bookmark.url)
    XCTAssertEqual(book.folderID, folder.id)
    XCTAssertFalse(book.hasWebReadingCopy)
    XCTAssertTrue(FileManager.default.fileExists(atPath: try repository.paths.url(book.originalPath).path))
    try await repository.updateBookMetadata(book.id, title: "自定书名", coverData: Data([1, 2, 3]))
    try await repository.batchEditBooks([book.id], favorite: true, finished: true, move: true)
    let position = ReadingPosition(locatorJSON: "{\"href\":\"article.xhtml\"}")
    try await repository.updateProgress(bookID: book.id, position: position, progress: 0.42)
    try await repository.markWebBookOpened(book.id, source: bookmark.url)
    let duplicate = try await repository.exportWebBookmarkToShelf(bookmark.id, folderID: folder.id)
    XCTAssertEqual(duplicate.id, book.id)
    XCTAssertEqual(duplicate.title, "自定书名")
    XCTAssertTrue(duplicate.isFavorite)
    XCTAssertTrue(duplicate.isFinished)
    XCTAssertNil(duplicate.folderID)
    XCTAssertNotNil(duplicate.customCoverPath)
    XCTAssertEqual(duplicate.progress, 0.42)
    XCTAssertEqual(duplicate.position, position)
    XCTAssertNotNil(duplicate.lastOpenedAt)
    try await repository.deleteWebBookmark(bookmark.id)
    let reopened = try LibraryRepository(root: root)
    let books = try await reopened.books()
    XCTAssertEqual(books, [duplicate])
    let bookmarks = try await reopened.webBookmarks()
    XCTAssertTrue(bookmarks.isEmpty)
  }

  // 已删除书目按原 ID 恢复，旧进度和笔记关联不产生第二份副本。
  func testDuplicateExportRestoresTrashedBook() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try LibraryRepository(root: root)
    let bookmark = try await repository.saveWebBookmark(address: "example.com", title: "网址")
    let book = try await repository.exportWebBookmarkToShelf(bookmark.id)
    try await repository.trashBooks([book.id])
    let restored = try await repository.exportWebBookmarkToShelf(bookmark.id)
    XCTAssertEqual(restored.id, book.id)
    XCTAssertNil(restored.deletedAt)
    let all = try await repository.books(includeDeleted: true)
    XCTAssertEqual(all.count, 1)
  }

  // 阅读模式按书目分别持久化，后台写入的正文和进度也不会被切换开关覆盖。
  func testReadingModeIsPerBookAndSurvivesReopening() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try LibraryRepository(root: root)
    let firstBookmark = try await repository.saveWebBookmark(address: "example.com/first", title: "第一本")
    let secondBookmark = try await repository.saveWebBookmark(address: "example.com/second", title: "第二本")
    let first = try await repository.exportWebBookmarkToShelf(firstBookmark.id)
    let second = try await repository.exportWebBookmarkToShelf(secondBookmark.id)
    XCTAssertNil(first.webReaderEnabled)
    try await repository.setWebReaderEnabled(true, for: first)
    let cached = try await repository.saveWebReadingCopy(bookID: first.id, source: firstBookmark.url, article: article)
    let position = ReadingPosition(locatorJSON: "{\"href\":\"OEBPS/article.xhtml\"}")
    try await repository.updateProgress(bookID: first.id, position: position, progress: 0.4)

    // 用旧快照切换模式也只修改开关。另一本书仍沿用原网页默认值。
    let reopened = try LibraryRepository(root: root)
    let actualFirst = try await reopened.book(first.id)
    let actualSecond = try await reopened.book(second.id)
    XCTAssertEqual(actualFirst.webReaderEnabled, true)
    XCTAssertNil(actualSecond.webReaderEnabled)
    try await reopened.setWebReaderEnabled(false, for: first)
    let switchedOff = try await reopened.book(first.id)
    XCTAssertEqual(switchedOff.webReaderEnabled, false)
    XCTAssertEqual(switchedOff.position, position)
    XCTAssertEqual(switchedOff.readingPath, cached.readingPath)
    XCTAssertEqual(switchedOff.progress, 0.4)
  }

  // 改链重置旧正文与定位，摘录批注保留，旧来源的晚到提取结果必须被拒绝。
  func testLinkEditingInvalidatesCopyAndPreservesNoteText() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try LibraryRepository(root: root)
    let bookmark = try await repository.saveWebBookmark(address: "example.com/old", title: "原书名")
    let book = try await repository.exportWebBookmarkToShelf(bookmark.id)
    let cached = try await repository.saveWebReadingCopy(bookID: book.id, source: bookmark.url, article: article)
    let position = ReadingPosition(locatorJSON: "{\"href\":\"article.xhtml\"}")
    try await repository.updateProgress(bookID: book.id, position: position, progress: 0.7)
    let note = Annotation(bookID: book.id, kind: .highlight, position: position, quote: "摘录", note: "批注")
    try await repository.saveAnnotation(note)
    try await repository.updateBookMetadata(book.id, title: "新标题", coverData: Data([7]), webAddress: "example.org/new")
    let updated = try await repository.book(book.id)
    XCTAssertEqual(updated.id, book.id)
    XCTAssertEqual(updated.title, "新标题")
    XCTAssertEqual(updated.webURL?.absoluteString, "https://example.org/new")
    XCTAssertEqual(updated.progress, 0)
    XCTAssertNil(updated.position)
    XCTAssertNil(updated.webSnapshotDate)
    XCTAssertFalse(updated.hasWebReadingCopy)
    XCTAssertNotEqual(updated.originalPath, cached.originalPath)
    XCTAssertFalse(FileManager.default.fileExists(atPath: try repository.paths.url(cached.readingPath).path))
    let notes = try await repository.annotations(bookID: book.id)
    XCTAssertEqual(notes.first?.quote, "摘录")
    XCTAssertEqual(notes.first?.note, "批注")
    XCTAssertEqual(notes.first?.position, ReadingPosition())
    let bookmarks = try await repository.webBookmarks()
    XCTAssertEqual(bookmarks.first?.url, bookmark.url)
    do {
      _ = try await repository.saveWebReadingCopy(bookID: book.id, source: bookmark.url, article: article)
      XCTFail("旧链接提取结果应被拒绝")
    } catch {}
    let stillCurrent = try await repository.book(book.id)
    XCTAssertEqual(stillCurrent, updated)
  }

  // 无效链接、冲突链接和不存在的目标书架不能留下部分修改。
  func testInvalidEditsAndExportPreserveRecords() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try LibraryRepository(root: root)
    let first = try await repository.saveWebBookmark(address: "example.com/a", title: "甲")
    let second = try await repository.saveWebBookmark(address: "example.com/b", title: "乙")
    let book = try await repository.exportWebBookmarkToShelf(first.id)
    _ = try await repository.exportWebBookmarkToShelf(second.id)
    for address in ["javascript:alert(1)", second.url.absoluteString] {
      do {
        try await repository.updateBookMetadata(book.id, title: "不应保存", coverData: Data([2]), webAddress: address)
        XCTFail("应拒绝无效或冲突链接")
      } catch {}
      let unchanged = try await repository.book(book.id)
      XCTAssertEqual(unchanged, book)
    }
    do { _ = try await repository.exportWebBookmarkToShelf(first.id, folderID: UUID()); XCTFail("不存在的书架") } catch {}
    XCTAssertThrowsError(try BookFormat.detect(URL(fileURLWithPath: "/test.web")))
    XCTAssertNil(CalibreDownload(url: URL(string: "https://example.com/test.web")!, mediaType: "application/octet-stream"))
  }

  // 正文 EPUB 有目录、合法 XML、转义文字和本地图片，不携带网站脚本及远程图片。
  func testArticleEPUBStructureAndSanitization() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = root.appendingPathComponent("article.epub")
    let image = WebArticleImage(url: URL(string: "https://example.com/image.png")!,
      data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aO8sAAAAASUVORK5CYII=")!, mediaType: "image/png")
    try await WebArticleConverter.convert(article, images: [image], source: URL(string: "https://example.com/?a=1&b=2")!,
      title: "自定书名", destination: destination)
    let metadata = try await EbookArchive.metadata(at: destination)
    XCTAssertEqual(metadata.title, "自定书名")
    XCTAssertEqual(metadata.author, article.byline)
    let archive = try await Archive(url: destination, accessMode: .read)
    for path in ["OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/article.xhtml"] {
      let data = try await EbookArchive.read(archive, path: path)
      XCTAssertTrue(XMLParser(data: data).parse(), path)
    }
    let html = String(decoding: try await EbookArchive.read(archive, path: "OEBPS/article.xhtml"), as: UTF8.self)
    XCTAssertFalse(html.contains("<script>"))
    XCTAssertFalse(html.contains("src=\"https:"))
    XCTAssertTrue(html.contains("&lt;script&gt;"))
    XCTAssertTrue(html.contains("images/image0.png"))
    XCTAssertTrue(html.contains("section0"))
    XCTAssertFalse(html.contains("\u{1}"))
  }

  // 用相对片段在真实离线 EPUB 内定位注释，校验 UTF-16 区间与 XML 转义。
  func testArticleEPUBPreservesFootnoteLinks() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = root.appendingPathComponent("footnotes.epub")
    let text = "星空 😀 与〔注〕。<正文>"
    let range = (text as NSString).range(of: "〔注〕")
    var paragraph = WebArticleBlock(.paragraph, text: text)
    paragraph.noteReferences = [
      .init(offset: 0, length: Int.max, noteID: 0),
      .init(offset: range.location, length: range.length, noteID: 0),
      .init(offset: range.location, length: range.length, noteID: 0),
      .init(offset: 0, length: 2, noteID: 10),
    ]
    var note = WebArticleBlock(.footnote, text: "本地注释 <测试> & 解释\n第二行")
    note.noteID = 0
    let article = WebArticle(title: "注释样书", blocks: [paragraph, note])

    // 转换和解析同一 XHTML，保证生成的文档能进入普通 EPUB 阅读路径。
    try await WebArticleConverter.convert(article, source: URL(string: "https://example.com/article")!,
      title: article.title, destination: destination)
    let archive = try await Archive(url: destination, accessMode: .read)
    let data = try await EbookArchive.read(archive, path: "OEBPS/article.xhtml")
    XCTAssertTrue(XMLParser(data: data).parse())
    let html = String(decoding: data, as: UTF8.self)
    XCTAssertEqual(html.components(separatedBy: ##"href="#miolib-note-0""##).count, 2)
    XCTAssertTrue(html.contains(#"epub:type="noteref" role="doc-noteref">〔注〕</a>"#))
    XCTAssertTrue(html.contains(#"id="miolib-note-0" epub:type="footnote""#))
    XCTAssertTrue(html.contains("星空 😀 与"))
    XCTAssertTrue(html.contains("&lt;正文&gt;"))
    XCTAssertTrue(html.contains("本地注释 &lt;测试&gt; &amp; 解释<br/>第二行"))
    XCTAssertFalse(html.contains("miolib-note-10"))
  }

  // 已缓存和未缓存书目都能完整备份；恢复后再次导出同一收藏仍复用书目。
  func testBackupWithCachedAndUncachedWebBooks() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try LibraryRepository(root: root.appendingPathComponent("source"))
    let first = try await source.saveWebBookmark(address: "example.com/cached", title: "已缓存")
    let second = try await source.saveWebBookmark(address: "example.com/link", title: "未缓存")
    let cachedBook = try await source.exportWebBookmarkToShelf(first.id)
    let linkBook = try await source.exportWebBookmarkToShelf(second.id)
    let cached = try await source.saveWebReadingCopy(bookID: cachedBook.id, source: first.url, article: article)
    let repeated = try await source.saveWebReadingCopy(bookID: cachedBook.id, source: first.url,
      article: WebArticle(title: "不覆盖旧正文", blocks: [.init(.paragraph, text: "更新后的文字")]))
    XCTAssertEqual(repeated, cached)
    let backup = root.appendingPathComponent("webbooks.miolib")
    try await source.exportBackup(to: backup)
    let archive = try await Archive(url: backup, accessMode: .read)
    let manifest = try LibraryJSON.decode(BackupManifest.self, from: await EbookArchive.read(archive, path: "manifest.json"))
    XCTAssertEqual(manifest.version, 4)
    let target = try LibraryRepository(root: root.appendingPathComponent("target"))
    try await target.restoreBackup(from: backup)
    let restored = try await target.book(cached.id)
    let uncached = try await target.book(linkBook.id)
    XCTAssertTrue(restored.hasWebReadingCopy)
    XCTAssertTrue(restored.hasWebCacheRecord)
    XCTAssertEqual(restored.webSnapshotDate, cached.webSnapshotDate)
    XCTAssertEqual(restored.webURL, first.url)
    XCTAssertFalse(uncached.hasWebReadingCopy)
    XCTAssertFalse(uncached.hasWebCacheRecord)
    XCTAssertEqual(uncached.originalPath, uncached.readingPath)
    let metadata = try await EbookArchive.metadata(at: target.paths.url(restored.readingPath))
    XCTAssertEqual(metadata.title, cached.title)
    let duplicate = try await target.exportWebBookmarkToShelf(first.id)
    XCTAssertEqual(duplicate.id, cached.id)
    let backupAgain = root.appendingPathComponent("restored.miolib")
    try await target.exportBackup(to: backupAgain)
  }

  // 旧版书籍 JSON 缺少网页字段仍正常解码，不改变原格式和阅读路径。
  func testLegacyBookDecoding() throws {
    let book = Book(title: "旧 EPUB", format: .epub, originalPath: "Originals/old.epub",
      readingPath: "Originals/old.epub", fingerprint: "old")
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryJSON.encode(book)) as? [String: Any])
    json.removeValue(forKey: "webURL")
    json.removeValue(forKey: "webSnapshotDate")
    let decoded = try LibraryJSON.decode(Book.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertEqual(decoded, book)
    XCTAssertNil(decoded.webURL)
    XCTAssertFalse(decoded.hasWebReadingCopy)
  }

  // 空正文或伪造图片不能生成可发布的阅读副本，原书目仍保持未缓存状态。
  func testInvalidArticleDoesNotCommitCopy() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try LibraryRepository(root: root)
    let bookmark = try await repository.saveWebBookmark(address: "example.com", title: "链接")
    let book = try await repository.exportWebBookmarkToShelf(bookmark.id)
    do {
      _ = try await repository.saveWebReadingCopy(bookID: book.id, source: bookmark.url,
        article: WebArticle(title: "空页", blocks: []))
      XCTFail("空正文应拒绝")
    } catch {}
    let image = WebArticleImage(url: bookmark.url, data: Data("<svg/>".utf8), mediaType: "image/jpeg")
    do {
      _ = try await repository.saveWebReadingCopy(bookID: book.id, source: bookmark.url, article: article, images: [image])
      XCTFail("伪造图片应拒绝")
    } catch {}
    let unchanged = try await repository.book(book.id)
    XCTAssertEqual(unchanged, book)
    let files = try FileManager.default.contentsOfDirectory(atPath: repository.paths.root.appendingPathComponent("Reading").path)
    XCTAssertTrue(files.isEmpty)
  }

  // 备份维护期间新入口不能导出、修改访问时间或提交正文，避免快照与写入交叉。
  func testMaintenanceRejectsWebBookWrites() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try LibraryRepository(root: root)
    let bookmark = try await repository.saveWebBookmark(address: "example.com", title: "链接")
    let book = try await repository.exportWebBookmarkToShelf(bookmark.id)
    await repository.setMaintenanceForBookTest(true)
    do { _ = try await repository.exportWebBookmarkToShelf(bookmark.id); XCTFail("维护期间不能导出") } catch {}
    do { try await repository.markWebBookOpened(book.id, source: bookmark.url); XCTFail("维护期间不能写访问时间") } catch {}
    do {
      _ = try await repository.saveWebReadingCopy(bookID: book.id, source: bookmark.url, article: article)
      XCTFail("维护期间不能保存正文")
    } catch {}
    await repository.setMaintenanceForBookTest(false)
    let current = try await repository.book(book.id)
    XCTAssertEqual(current, book)
  }

  // 每项测试创建独立书库目录，失败后也只清理该测试生成的文件。
  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }
}

// 维护锁测试只使用测试扩展，生产接口保持只读访问规则。
private extension LibraryRepository {
  func setMaintenanceForBookTest(_ value: Bool) { maintenance = value }
}
