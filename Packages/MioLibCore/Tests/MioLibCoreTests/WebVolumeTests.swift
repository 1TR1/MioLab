import Foundation
import MioZIPFoundation
import XCTest
@testable import MioLibCore

// 用临时书库验证卷选择、删卷、备份和实际离线资源，测试不访问网站。
final class WebVolumeTests: XCTestCase {
  private let first = URL(string: "https://www.wenku8.net/novel/0/1/2.htm")!
  private let firstExtra = URL(string: "https://www.wenku8.net/novel/0/1/4.htm")!
  private let second = URL(string: "https://www.wenku8.net/novel/0/1/37.htm")!
  private let imageURL = URL(string: "https://img.example.com/volume.png")!
  private let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/6XsAAAAASUVORK5CYII=")!
  private var volumes: [WebBookVolume] {
    [.init(title: "第一卷", chapterURLs: [first, firstExtra]), .init(title: "第二卷", chapterURLs: [second])]
  }

  // 保存只创建书目，随后确认第二卷时才允许对应章节进入离线书库。
  func testExportWaitsForExplicitVolumeChoice() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try LibraryRepository(root: root)
    let bookmark = try await repository.saveWebBookmark(address: first.absoluteString, title: "选卷样书")
    let exported = try await repository.exportWebBookmarkToShelf(bookmark.id, selectedVolumes: [])
    XCTAssertFalse(exported.hasWebCacheSelection)
    XCTAssertFalse(exported.hasWebReadingCopy)
    XCTAssertFalse(exported.hasWebCacheRecord)
    XCTAssertNil(exported.webVolumes)
    do {
      _ = try await repository.saveWebReadingCopy(bookID: exported.id, source: first, article: article(at: first))
      XCTFail("确认选卷前不能写入首章")
    } catch {}

    // 选择弹窗从书签 URL 识别卷目录，但缓存只覆盖确认的第二卷。
    var directoryOnly = exported
    directoryOnly.webVolumes = volumes
    XCTAssertFalse(directoryOnly.hasWebCacheRecord)
    let book = try await repository.chooseWebCacheVolumes([volumes[1].id], for: exported, catalog: volumes)
    XCTAssertTrue(book.hasWebCacheRecord)
    XCTAssertFalse(book.hasWebReadingCopy)
    XCTAssertFalse(book.allowsWebCaching(at: first))
    let alias = try XCTUnwrap(URL(string: "http://wenku8.net/novel/0/1/37.htm#image"))
    XCTAssertTrue(book.allowsWebCaching(at: alias))
    do {
      _ = try await repository.saveWebReadingCopy(bookID: book.id, source: first, article: article(at: first))
      XCTFail("未选卷不应该成为首章")
    } catch {}

    // 首章实际跳到同站别名时，仍按所选目录完成且不会重复下载。
    let cached = try await repository.saveWebReadingCopy(bookID: book.id, source: first, article: article(at: alias))
    let complete = try await repository.publishWebChapters(for: cached, directory: [second], completesBook: true)
    XCTAssertEqual(complete.cachedWebChapters.count, 1)
    XCTAssertTrue(complete.webCacheCompleted == true)
    do {
      _ = try await repository.stageWebChapter(for: complete, chapterURL: first, article: article(at: first))
      XCTFail("已选卷完成后仍应拒绝未选卷")
    } catch {}
    let reopened = try LibraryRepository(root: root)
    let stored = try await reopened.book(book.id)
    XCTAssertTrue(stored.hasWebCacheRecord)
    XCTAssertEqual(stored.webVolumes, volumes)
    XCTAssertEqual(stored.webVolumeIDs, [volumes[1].id])
    let duplicate = try await reopened.exportWebBookmarkToShelf(bookmark.id, selectedVolumes: [])
    XCTAssertEqual(duplicate, stored)
  }

  // 换选另一卷不会清理原来的正文或未合并章，旧下载也不能继续提交章节。
  func testNewChoiceReplacesDownloadsAndPreservesPreviousCache() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try LibraryRepository(root: root)
    let book = try await export(to: repository, selection: [volumes[0].id])
    let cached = try await repository.saveWebReadingCopy(bookID: book.id, source: first, article: article(at: first))
    try await repository.updateProgress(bookID: book.id, position: cached.cachedWebChapters[0].startPosition, progress: 0.5)
    let staged = try await repository.stageWebChapter(for: cached, chapterURL: firstExtra, article: article(at: firstExtra))
    let updated = try await repository.chooseWebCacheVolumes([volumes[1].id], for: staged)
    XCTAssertEqual(updated.webVolumeIDs, [volumes[1].id])
    XCTAssertEqual(updated.cachedWebChapters, staged.cachedWebChapters)
    XCTAssertEqual(updated.webPendingChapters, staged.webPendingChapters)
    XCTAssertEqual(updated.position, staged.position)
    XCTAssertFalse(updated.allowsWebCaching(at: first))
    XCTAssertTrue(updated.allowsWebCaching(at: second))

    // 旧任务以及目录外的新选择必须失败，最新请求可以接着落盘。
    do {
      _ = try await repository.stageWebChapter(for: staged, chapterURL: second, article: article(at: second))
      XCTFail("旧选择对应的任务应失效")
    } catch {}
    do {
      _ = try await repository.chooseWebCacheVolumes(["unknown-volume"], for: updated)
      XCTFail("不接受目录外的卷")
    } catch {}
    try await repository.stageWebChapter(for: updated, chapterURL: second, article: article(at: second))
    let complete = try await repository.publishWebChapters(for: updated, directory: [second], completesBook: true)
    XCTAssertEqual(complete.cachedWebChapters.map(\.url), [first, firstExtra, second])
  }

  // 删已发布和待合并的同一卷，同时保留别卷正文、图片、进度和本书笔记。
  func testRemoveVolumeKeepsOtherFilesAndBackupRestoresLocator() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try LibraryRepository(root: root.appendingPathComponent("library"))
    let book = try await export(to: repository, selection: nil)
    let seeded = try await repository.saveWebReadingCopy(bookID: book.id, source: first, article: article(at: first))
    try await repository.stageWebChapter(for: seeded, chapterURL: second, article: article(at: second, illustrated: true),
      images: [WebArticleImage(url: imageURL, data: image, mediaType: "image/png")])
    let combined = try await repository.publishWebChapters(for: seeded, directory: [first, firstExtra, second])
    let pending = try await repository.stageWebChapter(for: combined, chapterURL: firstExtra, article: article(at: firstExtra))
    let removedChapter = try XCTUnwrap(pending.cachedWebChapters.first)
    let retainedChapter = try XCTUnwrap(pending.cachedWebChapters.last)
    let stagedFile = try repository.paths.url(XCTUnwrap(pending.webPendingChapters?.first?.readingPath))
    let note = Annotation(bookID: book.id, kind: .highlight, position: removedChapter.startPosition, quote: "第一卷批注")
    try await repository.saveAnnotation(note)
    try await repository.updateProgress(bookID: book.id, position: retainedChapter.startPosition, progress: 0.6)

    // 已打开的旧书页持有原包，退出后原包才回收。已移除的源章会即刻释放。
    let held = await repository.retainWebReadingPath(combined.readingPath)
    XCTAssertTrue(held)
    let deleted = try await repository.setWebVolumeCached(false, volumeID: volumes[0].id, for: pending)
    XCTAssertEqual(deleted.webVolumeIDs, [volumes[1].id])
    XCTAssertEqual(deleted.cachedWebChapters, [retainedChapter])
    XCTAssertNil(deleted.webPendingChapters)
    XCTAssertEqual(deleted.position, retainedChapter.startPosition)
    XCTAssertFalse(FileManager.default.fileExists(atPath: try repository.paths.url(removedChapter.readingPath).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: stagedFile.path))
    let oldFile = try repository.paths.url(combined.readingPath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
    await repository.releaseWebReadingPath(combined.readingPath)
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
    let remaining = try await Archive(url: repository.paths.url(deleted.readingPath), accessMode: .read)
    let retainedImage = try await EbookArchive.read(remaining, path: "OEBPS/" + retainedChapter.resourcePrefix + "images/image0.png")
    XCTAssertEqual(retainedImage, image)
    let entries = try await remaining.entries()
    XCTAssertFalse(entries.contains { $0.path == removedChapter.href })

    // 旧任务和旧阅读器不能把被删首章重新写回，跨备份恢复后仍保留批注。
    do {
      _ = try await repository.stageWebChapter(for: pending, chapterURL: first, article: article(at: first))
      XCTFail("删除前的任务应该失效")
    } catch {}
    try await repository.updateProgress(bookID: book.id, position: removedChapter.startPosition, progress: 0.1,
      webSourcePath: book.originalPath)
    let keptPosition = try await repository.book(book.id).position
    XCTAssertEqual(keptPosition, retainedChapter.startPosition)
    let backup = root.appendingPathComponent("volumes.miolib")
    try await repository.exportBackup(to: backup)
    let target = try LibraryRepository(root: root.appendingPathComponent("restored"))
    try await target.restoreBackup(from: backup)
    let restored = try await target.book(book.id)
    let notes = try await target.annotations(bookID: book.id)
    XCTAssertEqual(notes, [note])
    XCTAssertFalse(restored.allowsWebCaching(at: first))
    let selected = try await target.setWebVolumeCached(true, volumeID: volumes[0].id, for: restored)
    try await target.stageWebChapter(for: selected, chapterURL: first, article: article(at: first))
    let republished = try await target.publishWebChapters(for: selected, directory: [first, second])
    XCTAssertEqual(republished.cachedWebChapters.first?.href, removedChapter.href)
  }

  // 删到无缓存时只留下链接。先下载原书的非首章时，也能沿用原章的前缀。
  func testRemoveLastVolumeAndRestoreNonRootChapter() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try LibraryRepository(root: root)
    let book = try await export(to: repository, selection: nil)
    let seeded = try await repository.saveWebReadingCopy(bookID: book.id, source: first, article: article(at: first))
    let combined = try await repository.appendWebChapter(bookID: book.id, source: first, chapterURL: second,
      article: article(at: second))
    let secondChapter = try XCTUnwrap(combined.cachedWebChapters.last)
    let one = try await repository.setWebVolumeCached(false, volumeID: volumes[0].id, for: combined)
    let zero = try await repository.setWebVolumeCached(false, volumeID: volumes[1].id, for: one)
    XCTAssertFalse(zero.hasWebReadingCopy)
    XCTAssertFalse(zero.hasWebCacheSelection)
    XCTAssertTrue(zero.hasWebCacheRecord)
    XCTAssertEqual(zero.readingPath, seeded.originalPath)
    XCTAssertNil(zero.position)
    XCTAssertEqual(zero.progress, 0)
    let selected = try await repository.setWebVolumeCached(true, volumeID: volumes[1].id, for: zero)
    let redownloaded = try await repository.saveWebReadingCopy(bookID: book.id, source: first, article: article(at: second))
    XCTAssertEqual(redownloaded.webVolumeIDs, selected.webVolumeIDs)
    XCTAssertEqual(redownloaded.cachedWebChapters.first?.href, secondChapter.href)
    let archive = try await Archive(url: repository.paths.url(redownloaded.readingPath), accessMode: .read)
    let body = try await EbookArchive.read(archive, path: secondChapter.href)
    XCTAssertFalse(body.isEmpty)
  }

  // 测试将第一卷的一个章页作为正式书签，模拟从中间选卷导出。
  private func export(to repository: LibraryRepository, selection: Set<String>?) async throws -> Book {
    let bookmark = try await repository.saveWebBookmark(address: first.absoluteString, title: "分卷样书")
    return try await repository.exportWebBookmarkToShelf(bookmark.id, volumes: volumes, selectedVolumes: selection)
  }

  private func article(at url: URL, illustrated: Bool = false) -> WebArticle {
    var value = WebArticle(title: "测试章节", blocks: [.init(.paragraph, text: "用于验证分卷缓存的章节。")])
    if illustrated { value.blocks.append(.init(.image, text: "插图", url: imageURL)) }
    value.pageURL = url
    return value
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }
}
