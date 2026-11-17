import Foundation
import XCTest
@testable import MioLibCore

// 末页判定覆盖单页、双页展开及缺少全局位置的文字书，百分比必须和实际完成状态一致。
final class ReadingProgressTests: XCTestCase {
  func testPDFLastPageIncludingSinglePage() {
    XCTAssertEqual(ReadingProgress.pdf(page: 0, count: 0), 0)
    XCTAssertEqual(ReadingProgress.pdf(page: 0, count: 1), 1)
    XCTAssertEqual(ReadingProgress.pdf(page: 0, count: 10), 0)
    XCTAssertEqual(ReadingProgress.pdf(page: 8, count: 10), 8.0 / 9.0)
    XCTAssertEqual(ReadingProgress.pdf(page: 9, count: 10), 1)
    XCTAssertEqual(ReadingProgress.pdf(page: 100, count: 10), 1)
  }
  func testVisibleEndingMarksTextCompleteWithoutFalsifyingEarlierPages() {
    XCTAssertEqual(ReadingProgress.text(raw: 0.94, isLastResource: true, visibleResourceEnd: 1), 1)
    XCTAssertEqual(ReadingProgress.text(raw: 0, isLastResource: true, visibleResourceEnd: 1), 1)
    XCTAssertEqual(ReadingProgress.text(raw: 0.4, isLastResource: false, visibleResourceEnd: 1), 0.4)
    XCTAssertEqual(ReadingProgress.text(raw: 0.94, isLastResource: true, visibleResourceEnd: 0.98), 0.94)
    XCTAssertEqual(ReadingProgress.text(raw: .nan, isLastResource: false, visibleResourceEnd: nil), 0)
  }
  func testPercentDoesNotRoundUpBeforeTheEnd() {
    XCTAssertEqual(ReadingProgress.percent(0.999999999), 99)
    XCTAssertEqual(ReadingProgress.percent(0.58), 58)
    XCTAssertEqual(ReadingProgress.percent(1), 100)
    XCTAssertEqual(ReadingProgress.percent(.infinity), 0)
    XCTAssertEqual(ReadingProgress.percent(-1), 0)
  }
}

// 以真实 SQLite、导入与备份走完整数据链，检查批量修改只影响所选书籍并可整体回滚。
final class LibraryEditingTests: XCTestCase {
  private var scratch: URL!
  private var repository: LibraryRepository!
  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryEditing-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    repository = try LibraryRepository(root: scratch.appendingPathComponent("Library"))
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }
  private func imported(_ name: String) async throws -> Book {
    let source = scratch.appendingPathComponent(name + ".txt")
    try Data("第一章 \(name)\n正文内容：\(name)".utf8).write(to: source)
    let importer = ImportService(repository: repository)
    let result = await importer.process(try await importer.enqueue(source: source))
    XCTAssertEqual(result.state, .completed)
    return try await repository.book(XCTUnwrap(result.bookID))
  }

  func testBatchAppliesOnlyChosenFieldsAndBooks() async throws {
    let first = try await imported("甲")
    let second = try await imported("乙")
    let other = try await imported("丙")
    let position = ReadingPosition(locatorJSON: "{\"href\":\"chapter.xhtml\"}")
    try await repository.updateProgress(bookID: first.id, position: position, progress: 0.58)
    let folder = LibraryFolder(title: "批量目标")
    try await repository.saveFolder(folder)
    try await repository.batchEditBooks([first.id, second.id], favorite: true, finished: true,
      move: true, folderID: folder.id)
    let changed = try await repository.book(first.id)
    let untouched = try await repository.book(other.id)
    XCTAssertTrue(changed.isFavorite)
    XCTAssertTrue(changed.isFinished)
    XCTAssertEqual(changed.folderID, folder.id)
    XCTAssertEqual(changed.progress, 0.58)
    XCTAssertEqual(changed.position, position)
    XCTAssertEqual(untouched, other)
    try await repository.batchEditBooks([first.id], favorite: false)
    let again = try await repository.book(first.id)
    XCTAssertFalse(again.isFavorite)
    XCTAssertTrue(again.isFinished)
    XCTAssertEqual(again.folderID, folder.id)
  }

  func testInvalidBatchRollsBackAndPreservesOriginal() async throws {
    let book = try await imported("回滚")
    do {
      try await repository.batchEditBooks([book.id, UUID()], favorite: true)
      XCTFail("失效的书籍应使整批失败")
    } catch {}
    do {
      try await repository.batchEditBooks([book.id], favorite: true, move: true, folderID: UUID())
      XCTFail("失效的目录应使整批失败")
    } catch {}
    let after = try await repository.book(book.id)
    XCTAssertEqual(after, book)
  }

  func testMetadataCoverDoesNotOverwriteLatestProgress() async throws {
    let original = try await imported("封面测试")
    let position = ReadingPosition(locatorJSON: "{\"href\":\"last.xhtml\"}")
    try await repository.updateProgress(bookID: original.id, position: position, progress: 1)
    try await repository.updateBookMetadata(original.id, title: "自定标题", coverData: Data([1, 2, 3]))
    var current = try await repository.book(original.id)
    XCTAssertEqual(current.progress, 1)
    XCTAssertEqual(current.position, position)
    XCTAssertEqual(current.title, "自定标题")
    XCTAssertNotNil(current.customCoverPath)
    try await repository.updateBookMetadata(original.id, title: original.originalTitle, resetCover: true)
    current = try await repository.book(original.id)
    XCTAssertNil(current.customCoverPath)
    XCTAssertNil(current.customTitle)
    XCTAssertEqual(current.progress, 1)
  }

  func testFolderCoverSnapshotSurvivesSourceBookDeletionAndBackup() async throws {
    let book = try await imported("封面来源")
    let image = Data([255, 216, 1, 2, 3, 255, 217])
    try await repository.updateBookMetadata(book.id, coverData: image)
    let selected = try await repository.book(book.id)
    let selectedData = try Data(contentsOf: repository.paths.url(XCTUnwrap(selected.effectiveCover)))
    let folderCover = try await repository.storeCover(selectedData)
    let folder = LibraryFolder(title: "书籍封面文件夹", coverPath: folderCover)
    try await repository.saveFolder(folder)
    XCTAssertNotEqual(folderCover, selected.effectiveCover)
    try await repository.updateBookMetadata(book.id, coverData: Data([4, 5, 6]))
    try await repository.trashBooks([book.id])
    let backup = scratch.appendingPathComponent("封面.miolib")
    try await repository.exportBackup(to: backup)
    let restored = try LibraryRepository(root: scratch.appendingPathComponent("Restored"))
    try await restored.restoreBackup(from: backup)
    let folders = try await restored.folders()
    let path = try XCTUnwrap(folders.first?.coverPath)
    XCTAssertEqual(try Data(contentsOf: restored.paths.url(path)), image)
  }

  func testFolderCoverScopeIncludesDescendantsOnly() {
    let root = LibraryFolder(title: "主目录")
    let child = LibraryFolder(parentID: root.id, title: "子目录")
    let grandchild = LibraryFolder(parentID: child.id, title: "孙目录")
    let other = LibraryFolder(title: "无关目录")
    XCTAssertEqual(LibraryHierarchy.descendants(of: root.id, folders: [root, child, grandchild, other]),
      [root.id, child.id, grandchild.id])
  }
}
