import Foundation
import XCTest
@testable import MioLibCore

// 从真实落盘清单进入原导入器，覆盖插拔、中断、去重、元数据和旧任务兼容性。
final class CalibreUSBTests: XCTestCase {
  private var scratch: URL!
  private var documents: URL!
  private var repository: LibraryRepository!
  private var importer: ImportService!
  private var receiver: CalibreUSBReceiver!
  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent("MioLibUSBTests-" + UUID().uuidString)
    documents = scratch.appendingPathComponent("Documents")
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    repository = try LibraryRepository(root: scratch.appendingPathComponent("Library"))
    importer = ImportService(repository: repository)
    receiver = CalibreUSBReceiver(repository: repository, importer: importer)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

  // 模拟插件严格先传书、后原子发布清单的顺序，正文不同可用于后续重复检测。
  private func incoming(id: UUID = UUID(), ready: Bool = true, hash: String? = nil,
    filename: String = "book.txt", body: String = "第一章 USB\n由电脑 Calibre 经数据线直接传入。") throws -> URL
  {
    let directory = documents.appendingPathComponent(".CalibreUSB/\(id.uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = Data(body.utf8)
    try data.write(to: directory.appendingPathComponent("book.txt"))
    if ready {
      let manifest = CalibreUSBManifest(id: id, filename: filename, title: "Calibre 修改后的书名",
        author: "USB 作者", bytes: data.count, sha256: hash ?? FileFingerprint.hash(data))
      try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("transfer.json"), options: .atomic)
    }
    return directory
  }

  func testCompleteTransferImportsOnceAndCleansOnlyAfterSuccess() async throws {
    let folder = LibraryFolder(title: "USB 书籍")
    try await repository.saveFolder(folder)
    let directory = try incoming()
    let result = try await receiver.scan(documents: documents, folderID: folder.id)
    XCTAssertEqual(result.queued, 1)
    let second = try await receiver.scan(documents: documents, folderID: folder.id)
    XCTAssertEqual(second.queued, 0)
    let queued = try await repository.jobs()
    let done = await importer.process(try XCTUnwrap(queued.first))
    XCTAssertEqual(done.state, .completed)
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    _ = try await receiver.scan(documents: documents)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    let books = try await repository.books()
    XCTAssertEqual(books.count, 1)
    XCTAssertEqual(books[0].title, "Calibre 修改后的书名")
    XCTAssertEqual(books[0].author, "USB 作者")
    XCTAssertEqual(books[0].folderID, folder.id)
  }

  func testPartialAndCorruptTransfersNeverEnterLibrary() async throws {
    _ = try incoming(ready: false)
    var scan = try await receiver.scan(documents: documents)
    XCTAssertEqual(scan.queued, 0)
    let corrupt = try incoming(hash: String(repeating: "0", count: 64))
    scan = try await receiver.scan(documents: documents)
    XCTAssertEqual(scan.queued, 1)
    let queued = try await repository.jobs()
    let result = await importer.process(try XCTUnwrap(queued.first))
    XCTAssertEqual(result.state, .failed)
    let books = try await repository.books()
    XCTAssertTrue(books.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
    scan = try await receiver.scan(documents: documents)
    XCTAssertEqual(scan.queued, 0)
  }

  func testTraversalAndSymlinksRejectBeforeEnqueue() async throws {
    _ = try incoming(filename: "../../outside.txt")
    let linked = try incoming()
    try FileManager.default.removeItem(at: linked.appendingPathComponent("book.txt"))
    let external = scratch.appendingPathComponent("external.txt")
    try Data("外部原书".utf8).write(to: external)
    try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("book.txt"), withDestinationURL: external)
    let scan = try await receiver.scan(documents: documents)
    XCTAssertEqual(scan.queued, 0)
    XCTAssertEqual(scan.errors.count, 2)
    XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "外部原书")
  }

  func testOrphanedStagingResumesAndDuplicateFileDoesNotCreateBook() async throws {
    let id = UUID()
    _ = try incoming(id: id)
    let orphan = try repository.paths.url("Staging/\(id.uuidString)")
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    try Data("中断的半本书".utf8).write(to: orphan.appendingPathComponent("book.txt"))
    _ = try await receiver.scan(documents: documents)
    let first = try await repository.jobs()
    let result = await importer.process(try XCTUnwrap(first.first))
    XCTAssertEqual(result.state, .completed)
    _ = try await receiver.scan(documents: documents)
    _ = try incoming()
    _ = try await receiver.scan(documents: documents)
    let jobs = try await repository.jobs()
    let duplicate = await importer.process(try XCTUnwrap(jobs.first { $0.state == .queued }))
    XCTAssertEqual(duplicate.state, .duplicate)
    let books = try await repository.books()
    XCTAssertEqual(books.count, 1)
  }

  func testOlderImportJobDecodesWithoutUSBFields() throws {
    let old = ImportJob(name: "旧书.txt", stagedPath: "Staging/old/旧书.txt")
    let decoded = try JSONDecoder().decode(ImportJob.self, from: JSONEncoder().encode(old))
    XCTAssertNil(decoded.sourceFingerprint)
    XCTAssertNil(decoded.sourceTitle)
    XCTAssertEqual(decoded.id, old.id)
  }

  // 用户取消后即使清理完成记录也不能自动恢复该任务，只有主动重试才能继续。
  func testCancelledUSBJobRemainsCancelledAfterHistoryCleanup() async throws {
    _ = try incoming()
    _ = try await receiver.scan(documents: documents)
    let jobs = try await repository.jobs()
    var cancelled = try XCTUnwrap(jobs.first)
    cancelled.state = .cancelled
    try await repository.saveJob(cancelled)
    try await repository.clearCompletedJobs()
    let scan = try await receiver.scan(documents: documents)
    let saved = try await repository.job(cancelled.id)
    XCTAssertEqual(scan.queued, 0)
    XCTAssertEqual(saved?.state, .cancelled)
  }
}
