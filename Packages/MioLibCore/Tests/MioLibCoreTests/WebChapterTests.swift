import Foundation
import MioZIPFoundation
import XCTest
@testable import MioLibCore
#if canImport(FoundationXML)
  import FoundationXML
#endif

// 真实 SQLite、EPUB 与备份测试只操作临时文件，不访问小说站点或私人书库。
final class WebChapterTests: XCTestCase {
  private let first = URL(string: "https://www.wenku8.net/novel/0/1/2.htm")!
  private let next = URL(string: "https://www.wenku8.net/novel/0/1/37.htm")!

  // 章节 ID 不必连续，导航由页面给出；追加后原正文、图片路径和笔记位置保持不变。
  func testAppendKeepsOriginalResourcesAndAnnotationLocators() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try LibraryRepository(root: root)
    let initial = try await makeBook(repository)
    let firstArchive = try await Archive(url: repository.paths.url(initial.readingPath), accessMode: .read)
    let originalHTML = try await EbookArchive.read(firstArchive, path: "OEBPS/article.xhtml")
    let position = ReadingPosition(locatorJSON: "{\"href\":\"OEBPS/article.xhtml\",\"type\":\"application/xhtml+xml\",\"locations\":{\"progression\":0.5}}")
    let note = Annotation(bookID: initial.id, kind: .highlight, position: position, quote: "首章摘录", note: "原批注")
    try await repository.saveAnnotation(note)
    let updated = try await repository.appendWebChapter(bookID: initial.id, source: first, chapterURL: next,
      article: article("第二章", page: next, previous: first))
    XCTAssertEqual(updated.id, initial.id)
    XCTAssertEqual(updated.webURL, first)
    XCTAssertEqual(updated.cachedWebChapters.count, 2)
    XCTAssertEqual(updated.cachedWebChapters.first?.href, "OEBPS/article.xhtml")
    let second = try XCTUnwrap(updated.cachedWebChapters.last)
    XCTAssertTrue(second.href.hasPrefix("OEBPS/chapters/"))
    XCTAssertNotEqual(updated.readingPath, initial.readingPath)
    let combined = try await Archive(url: repository.paths.url(updated.readingPath), accessMode: .read)
    let retainedHTML = try await EbookArchive.read(combined, path: "OEBPS/article.xhtml")
    XCTAssertEqual(retainedHTML, originalHTML)
    let secondHTML = String(decoding: try await EbookArchive.read(combined, path: second.href), as: UTF8.self)
    XCTAssertTrue(secondHTML.contains("第二章"))
    for path in ["OEBPS/content.opf", "OEBPS/nav.xhtml", second.href] {
      let xml = try await EbookArchive.read(combined, path: path)
      XCTAssertTrue(XMLParser(data: xml).parse(), path)
    }
    let annotations = try await repository.annotations(bookID: initial.id)
    XCTAssertEqual(annotations, [note])
    XCTAssertEqual(updated.position, second.startPosition)
    let back = try await repository.selectWebChapter(bookID: initial.id, source: first, chapterURL: first)
    XCTAssertEqual(back.position, back.cachedWebChapters[0].startPosition)
    XCTAssertEqual(back.readingPath, updated.readingPath)
  }

  // 再次读取缓存章不创建副本；从中间开始往前读仍按实际顺序插入且不改变旧资源路径。
  func testDeduplicationPrependingAndCurrentChapterLookup() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try LibraryRepository(root: root)
    let initial = try await makeBook(repository)
    let previous = URL(string: "https://www.wenku8.net/novel/0/1/1.htm")!
    let prepended = try await repository.appendWebChapter(bookID: initial.id, source: first, chapterURL: previous,
      article: article("前一章", page: previous, next: first))
    XCTAssertEqual(prepended.cachedWebChapters.map(\.url), [previous, first])
    XCTAssertEqual(prepended.cachedWebChapters[1].href, "OEBPS/article.xhtml")
    XCTAssertEqual(prepended.webChapter(href: "OEBPS/article.xhtml#section1")?.url, first)
    let repeated = try await repository.appendWebChapter(bookID: initial.id, source: first, chapterURL: previous,
      article: article("不得覆盖", page: previous))
    XCTAssertEqual(repeated.cachedWebChapters, prepended.cachedWebChapters)
    XCTAssertEqual(repeated.readingPath, prepended.readingPath)
  }

  // 恢复后源章节与聚合副本一起迁移，下一次追加仍能读取每个章节的独立源文件。
  func testMultiChapterBackupRestoreAndAppendAfterRestore() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try LibraryRepository(root: root.appendingPathComponent("source"))
    let book = try await makeBook(repository)
    let second = try await repository.appendWebChapter(bookID: book.id, source: first, chapterURL: next,
      article: article("第二章", page: next, previous: first))
    let backup = root.appendingPathComponent("chapters.miolib")
    try await repository.exportBackup(to: backup)
    let target = try LibraryRepository(root: root.appendingPathComponent("target"))
    try await target.restoreBackup(from: backup)
    let restored = try await target.book(book.id)
    XCTAssertEqual(restored.cachedWebChapters.map(\.href), second.cachedWebChapters.map(\.href))
    for path in restored.assetPaths { XCTAssertTrue(FileManager.default.fileExists(atPath: try target.paths.url(path).path)) }
    let third = URL(string: "https://www.wenku8.net/novel/0/1/108.htm")!
    let appended = try await target.appendWebChapter(bookID: book.id, source: first, chapterURL: third,
      article: article("第三章", page: third, previous: next))
    XCTAssertEqual(appended.cachedWebChapters.count, 3)
    let archive = try await Archive(url: target.paths.url(appended.readingPath), accessMode: .read)
    for chapter in appended.cachedWebChapters {
      let html = try await EbookArchive.read(archive, path: chapter.href)
      XCTAssertFalse(html.isEmpty)
    }
    // 替换聚合副本只清理旧聚合文件，各章源副本仍然存在。
    XCTAssertFalse(FileManager.default.fileExists(atPath: try target.paths.url(restored.readingPath).path))
    for chapter in appended.cachedWebChapters {
      XCTAssertTrue(FileManager.default.fileExists(atPath: try target.paths.url(chapter.readingPath).path))
    }
  }

  // 目录或空正文失败不能替换现有书籍，修改来源后晚到章节不能写入新书链接。
  func testFailuresAndChangedSourcePreserveCurrentChapter() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try LibraryRepository(root: root)
    let initial = try await makeBook(repository)
    var contents = article("目录", page: next)
    contents.navigation = WebChapterNavigation(isContents: true)
    for invalid in [contents, WebArticle(title: "空页", blocks: [])] {
      do {
        _ = try await repository.appendWebChapter(bookID: initial.id, source: first, chapterURL: next, article: invalid)
        XCTFail("无效章节应被拒绝")
      } catch {}
      let unchanged = try await repository.book(initial.id)
      XCTAssertEqual(unchanged, initial)
    }
    try await repository.updateBookMetadata(initial.id, webAddress: "example.com/new")
    do {
      _ = try await repository.appendWebChapter(bookID: initial.id, source: first, chapterURL: next,
        article: article("晚到旧章", page: next))
      XCTFail("旧来源应被拒绝")
    } catch {}
    let changed = try await repository.book(initial.id)
    XCTAssertNil(changed.webChapters)
    XCTAssertFalse(changed.hasWebReadingCopy)
  }

  // 1.9.0 缓存缺少章节元数据时，可仅补导航并保留原 EPUB 与原进度。
  func testLegacySinglePageCacheNavigationMigration() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try LibraryRepository(root: root)
    var old = try await makeBook(repository)
    old.webChapters = nil
    try await repository.update(old)
    let updated = try await repository.updateWebChapterNavigation(bookID: old.id, source: first,
      chapterURL: first, navigation: WebChapterNavigation(nextURL: next))
    XCTAssertEqual(updated.readingPath, old.readingPath)
    XCTAssertEqual(updated.position, old.position)
    XCTAssertEqual(updated.cachedWebChapters.first?.navigation?.nextURL, next)
    let appended = try await repository.appendWebChapter(bookID: old.id, source: first, chapterURL: next,
      article: article("新章", page: next, previous: first))
    XCTAssertEqual(appended.cachedWebChapters[0].href, "OEBPS/article.xhtml")
  }

  // 页内锚点继续属于同一章；插图章可以保留目录与下一章入口，即使图片暂时无法下载。
  func testChapterAnchorsAndImageOnlyContent() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try LibraryRepository(root: root)
    let book = try await makeBook(repository)
    var images = WebArticle(title: "插图章", blocks: [.init(.image, text: "", url: URL(string: "https://example.com/image.jpg")!)])
    images.navigation = WebChapterNavigation(previousURL: first)
    let cached = try await repository.appendWebChapter(bookID: book.id, source: first, chapterURL: next, article: images)
    let anchored = URL(string: next.absoluteString + "#illustration")!
    let again = try await repository.appendWebChapter(bookID: book.id, source: first, chapterURL: anchored, article: images)
    XCTAssertEqual(again.cachedWebChapters.count, 2)
    XCTAssertEqual(again.readingPath, cached.readingPath)
    let archive = try await Archive(url: repository.paths.url(cached.readingPath), accessMode: .read)
    let html = String(decoding: try await EbookArchive.read(archive, path: cached.cachedWebChapters[1].href), as: UTF8.self)
    XCTAssertTrue(html.contains("图片暂不可用"))
  }

  // 整本下载按目录补齐首次打开章节前后的正文，下载与合并都不移动已有位置。
  func testWholeBookCacheKeepsPositionAndUsesDirectoryOrder() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try LibraryRepository(root: root)
    let book = try await makeBook(repository)
    let previous = try XCTUnwrap(URL(string: "https://www.wenku8.net/novel/0/1/1.htm"))
    let order = [previous, first, next]
    let position = ReadingPosition(locatorJSON: "{\"href\":\"OEBPS/article.xhtml\",\"type\":\"application/xhtml+xml\",\"locations\":{\"progression\":0.4}}")
    try await repository.updateProgress(bookID: book.id, position: position, progress: 0.4)
    let before = try await repository.book(book.id)
    let staged = try await repository.stageWebChapter(for: book, chapterURL: next, article: article("末章", page: next))
    XCTAssertEqual(staged.readingPath, book.readingPath)
    XCTAssertEqual(staged.position, position)
    do {
      _ = try await repository.publishWebChapters(for: book, directory: order, completesBook: true)
      XCTFail("漏章的目录不能标记为整本")
    } catch {}
    try await repository.stageWebChapter(for: book, chapterURL: previous, article: article("前章", page: previous))
    let finished = try await repository.publishWebChapters(for: book, directory: order, completesBook: true)
    XCTAssertEqual(finished.cachedWebChapters.map(\.url), order)
    XCTAssertEqual(finished.cachedWebChapters[1].href, "OEBPS/article.xhtml")
    XCTAssertEqual(finished.position, position)
    XCTAssertEqual(finished.progress, before.progress)
    XCTAssertEqual(finished.lastOpenedAt, before.lastOpenedAt)
    XCTAssertEqual(finished.webCacheCompleted, true)
    XCTAssertNil(finished.webPendingChapters)
    let archive = try await Archive(url: repository.paths.url(finished.readingPath), accessMode: .read)
    let nav = String(decoding: try await EbookArchive.read(archive, path: "OEBPS/nav.xhtml"), as: UTF8.self)
    let front = try XCTUnwrap(nav.range(of: "前章"))
    let middle = try XCTUnwrap(nav.range(of: "第一章"))
    let back = try XCTUnwrap(nav.range(of: "末章"))
    XCTAssertLessThan(front.lowerBound, middle.lowerBound)
    XCTAssertLessThan(middle.lowerBound, back.lowerBound)

    // 新包生成时保留正在阅读的旧聚合副本，关闭后再回收。
    let retained = await repository.retainWebReadingPath(finished.readingPath)
    XCTAssertTrue(retained)
    let extra = try XCTUnwrap(URL(string: "https://www.wenku8.net/novel/0/1/99.htm"))
    try await repository.stageWebChapter(for: finished, chapterURL: extra, article: article("新章", page: extra, previous: next))
    let extended = try await repository.publishWebChapters(for: finished, directory: order + [extra], completesBook: true)
    XCTAssertEqual(extended.cachedWebChapters.count, 4)
    let oldFile = try repository.paths.url(finished.readingPath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
    await repository.releaseWebReadingPath(finished.readingPath)
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
  }

  // 中断后源章节可以在数据库重开或备份恢复时继续使用，同一章不会重复下载落盘。
  func testPendingDownloadCanResumeAfterBackupAndRestore() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try LibraryRepository(root: root.appendingPathComponent("source"))
    let book = try await makeBook(source)
    let staged = try await source.stageWebChapter(for: book, chapterURL: next, article: article("待合并章", page: next))
    let fresh = try LibraryRepository(root: source.paths.root)
    let afterRestart = try await fresh.book(book.id)
    XCTAssertEqual(afterRestart.webPendingChapters, staged.webPendingChapters)
    let backup = root.appendingPathComponent("pending.miolib")
    try await fresh.exportBackup(to: backup)
    let target = try LibraryRepository(root: root.appendingPathComponent("target"))
    try await target.restoreBackup(from: backup)
    let restored = try await target.book(book.id)
    let pending = try XCTUnwrap(restored.webPendingChapters?.first)
    XCTAssertTrue(FileManager.default.fileExists(atPath: try target.paths.url(pending.readingPath).path))
    let duplicate = try await target.stageWebChapter(for: restored, chapterURL: next, article: article("重复章", page: next))
    XCTAssertEqual(duplicate.webPendingChapters, [pending])
    let merged = try await target.publishWebChapters(for: restored, directory: [first, next], completesBook: true)
    XCTAssertEqual(merged.cachedWebChapters.map(\.url), [first, next])
    XCTAssertNil(merged.webPendingChapters)
    XCTAssertEqual(merged.webCacheCompleted, true)
  }

  // 自写样文只模拟站点的章节数据，不在项目中分发第三方小说正文。
  private func article(_ title: String, page: URL, previous: URL? = nil, next: URL? = nil) -> WebArticle {
    var value = WebArticle(title: title, blocks: [.init(.paragraph, text: "这是一段测试章节切换与笔记定位的原创样文。"),
      .init(.heading, text: "章节内标题", level: 2)])
    value.pageURL = page
    value.navigation = WebChapterNavigation(previousURL: previous, nextURL: next)
    return value
  }

  // 测试通过正式入口创建并提取首章，后续测试始终沿用同一本书的 ID。
  private func makeBook(_ repository: LibraryRepository) async throws -> Book {
    let bookmark = try await repository.saveWebBookmark(address: first.absoluteString, title: "章节样书")
    let book = try await repository.exportWebBookmarkToShelf(bookmark.id)
    return try await repository.saveWebReadingCopy(bookID: book.id, source: first,
      article: article("第一章", page: first, next: next))
  }

  // 每项测试的临时根目录独立，退出后不会清理其他测试或真实书库。
  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }
}
