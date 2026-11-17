import XCTest
import MioZIPFoundation
import CLibMobi

@testable import MioLibCore

// 测试使用临时真实数据库与文件系统，验证用户数据的完整流程而非模拟调用。
final class CoreTests: XCTestCase {
  // 千本书库验证索引查询与快照加载，输出耗时以供后续设备测试比较。
  func testThousandBookLibrary() async throws {
    let repository=try store();let started=Date()
    for index in 0..<1000 {
      let book=Book(title:"样书 \(index)",format:.epub,originalPath:"Originals/\(index).epub",readingPath:"Originals/\(index).epub",fingerprint:FileFingerprint.hash(Data("book-\(index)".utf8)))
      try await repository.insert(book)
    }
    let inserted=Date().timeIntervalSince(started),queryStart=Date()
    let books=try await repository.books();let loaded=Date().timeIntervalSince(queryStart)
    let existing=try await repository.existingBook(fingerprint:FileFingerprint.hash(Data("book-999".utf8)))
    XCTAssertEqual(books.count,1000);XCTAssertEqual(existing?.title,"样书 999")
    print("MIOLIB_BENCHMARK insert1000=\(inserted)seconds snapshot1000=\(loaded)seconds")
  }

  // 二进制 NUL 不得被 C 字符串截断后伪装成成功解码的文本。
  func testEmbeddedNullTextRejectsAndLongParagraphSplits()throws{
    XCTAssertThrowsError(try TextBookConverter.decode(Data([0x61,0x00,0x62]),encoding:"UTF-8"))
    let chapters=TextBookConverter.chapters(String(repeating:"文",count:200_000))
    XCTAssertGreaterThan(chapters.count,1);XCTAssertLessThan(chapters.map{$0.text.count}.max()!,70_000)
  }
  // 上游真实 KF7、混合 KF8 与 HUFF/CDIC 样本必须生成可解析 EPUB。
  func testKindleSamplesAndDRMRejection() async throws {
    let repository=try store();let service=ImportService(repository:repository)
    for (name,ext) in [("sample-kf7","mobi"),("sample-kf8","azw3"),("sample-huffdic","mobi")] {
      let source=try XCTUnwrap(Bundle.module.url(forResource:name,withExtension:ext,subdirectory:"Fixtures"))
      let queued=try await service.enqueue(source:source)
      let finished=await service.process(queued)
      XCTAssertEqual(finished.state,.completed,"\(name)：\(finished.detail)")
      if let id=finished.bookID{let book=try await repository.book(id);let metadata=try await EbookArchive.metadata(at:repository.paths.url(book.readingPath));XCTAssertFalse(metadata.title.isEmpty)}
    }
    let kf8=try XCTUnwrap(Bundle.module.url(forResource:"sample-kf8",withExtension:"azw3",subdirectory:"Fixtures"))
    let pointer=try XCTUnwrap(mobi_init());defer{mobi_free(pointer)}
    XCTAssertEqual(mobi_load_filename(pointer,kf8.path),MOBI_SUCCESS)
    XCTAssertTrue(mobi_is_hybrid(pointer));XCTAssertTrue(mobi_is_kf8(pointer))
    let drm=try XCTUnwrap(Bundle.module.url(forResource:"sample-drm",withExtension:"mobi",subdirectory:"Fixtures"))
    let queued=try await service.enqueue(source:drm);let rejected=await service.process(queued)
    XCTAssertEqual(rejected.state,.failed);XCTAssertTrue(rejected.detail.contains("DRM"))
  }

  // 目标文件夹在等待期间被删除时，不得留下已提交书目或半成品阅读文件。
  func testFailedCommitCleansGeneratedFilesAndAllowsRetry() async throws {
    let repository=try store();let service=ImportService(repository:repository)
    let folder=LibraryFolder(title:"临时分类");try await repository.saveFolder(folder)
    let queued=try await service.enqueue(source:text(),folderID:folder.id)
    try await repository.deleteFolder(folder.id)
    let failed=await service.process(queued);XCTAssertEqual(failed.state,.failed)
    let books=try await repository.books();XCTAssertTrue(books.isEmpty)
    for directory in ["Originals","Reading"]{XCTAssertTrue(try FileManager.default.contentsOfDirectory(at:repository.paths.root.appendingPathComponent(directory),includingPropertiesForKeys:nil).isEmpty)}
    var retry=failed;retry.folderID=nil;let result=await service.process(retry);XCTAssertEqual(result.state,.completed)
  }

  // 取消任务保留暂存源文件，下一次重试能够正常完成。
  func testCancelledImportCanRetry() async throws {
    let repository=try store();let service=ImportService(repository:repository)
    let queued=try await service.enqueue(source:text())
    let task=Task{await service.process(queued)};task.cancel()
    let cancelled=await task.value;XCTAssertEqual(cancelled.state,.cancelled)
    let result=await service.process(cancelled);XCTAssertEqual(result.state,.completed)
  }

  // 恶意 ZIP 路径在写入磁盘前被拒绝，已有书目及原文件均应保留。
  func testRestoreRejectsTraversalBeforeMutation() async throws {
    let repository=try store();let service=ImportService(repository:repository)
    let queued=try await service.enqueue(source:text());_=await service.process(queued)
    let before=try await repository.books();let backup=scratch.appendingPathComponent("恶意.miolib")
    let archive=try await Archive(url:backup,accessMode:.create)
    try await archive.addEntry(with:"../outside",type:.file,uncompressedSize:3){offset,count in Data("bad".utf8).subdata(in:Int(offset)..<min(3,Int(offset)+count))}
    do{try await repository.restoreBackup(from:backup);XCTFail("应拒绝路径穿越")}catch{}
    let after=try await repository.books();XCTAssertEqual(before,after)
    XCTAssertFalse(FileManager.default.fileExists(atPath:scratch.appendingPathComponent("outside").path))
  }
  private var scratch: URL!
  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MioLibTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }
  private func store(_ name: String = "Library") throws -> LibraryRepository {
    try LibraryRepository(root: scratch.appendingPathComponent(name))
  }
  private func text(_ name: String = "样书.txt", body: String = "第一章 开始\n你好，世界。\n第二章 远方\n继续阅读。")
    throws -> URL
  {
    let url = scratch.appendingPathComponent(name)
    try Data(body.utf8).write(to: url)
    return url
  }

  // 标准向量与跨块输入验证增量哈希，避免去重和备份共享同一个错误算法。
  func testSHA256StandardVectors() {
    XCTAssertEqual(
      FileFingerprint.hash(Data()),
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    XCTAssertEqual(
      FileFingerprint.hash(Data("abc".utf8)),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    var hasher = FileFingerprint()
    for _ in 0..<1000 { hasher.update(Data(repeating: 97, count: 1000)) }
    XCTAssertEqual(
      hasher.finalize(), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
  }
  func testTextEncodingAndChapterRecognition() throws {
    XCTAssertEqual(try TextBookConverter.decode(Data([0xff, 0xfe, 0x60, 0x4f, 0x7d, 0x59])), "你好")
    XCTAssertEqual(try TextBookConverter.decode(Data([0xc4, 0xe3, 0xba, 0xc3])), "你好")
    let chapters = TextBookConverter.chapters("序言\n第一章 开始\n正文\nChapter 2 End\n结束")
    XCTAssertEqual(chapters.map(\.title), ["正文", "第一章 开始", "Chapter 2 End"])
    XCTAssertThrowsError(try TextBookConverter.decode(Data([0xff]), encoding: "UTF-8"))
  }
  func testFolderCycleSiblingNamesAndDeletePreservesBooks() async throws {
    let repository = try store()
    let first = LibraryFolder(title: "文学")
    try await repository.saveFolder(first)
    let second = LibraryFolder(parentID: first.id, title: "小说")
    try await repository.saveFolder(second)
    var moved = first
    moved.parentID = second.id
    do {
      try await repository.saveFolder(moved)
      XCTFail("应拒绝循环")
    } catch {}
    do {
      try await repository.saveFolder(LibraryFolder(title: "文学"))
      XCTFail("应拒绝同名")
    } catch {}
    let service = ImportService(repository: repository)
    let job = try await service.enqueue(source: text(), folderID: second.id)
    let done = await service.process(job)
    XCTAssertEqual(done.state, .completed)
    try await repository.deleteFolder(first.id)
    let books = try await repository.books()
    XCTAssertEqual(books.count, 1)
    XCTAssertNil(books[0].folderID)
    let folders = try await repository.folders()
    XCTAssertTrue(folders.isEmpty)
  }
  func testImportDuplicateRenameTrashAndRetry() async throws {
    let repository = try store()
    let service = ImportService(repository: repository)
    let source = try text()
    let queued = try await service.enqueue(source: source)
    let completed = await service.process(queued)
    XCTAssertEqual(completed.state, .completed)
    var book = try await repository.books().first!
    book.customTitle = "新书名"
    try await repository.update(book)
    let duplicate = try await service.enqueue(source: source)
    let result = await service.process(duplicate)
    XCTAssertEqual(result.state, .duplicate)
    try await repository.trashBooks([book.id])
    let trashed = try await repository.books()
    XCTAssertTrue(trashed.isEmpty)
    try await repository.undoTrash([book.id])
    let restored = try await repository.book(book.id)
    XCTAssertEqual(restored.title, "新书名")
    let bad = try text("损坏.epub", body: "not an epub")
    let badJob = try await service.enqueue(source: bad)
    let failed = await service.process(badJob)
    XCTAssertEqual(failed.state, .failed)
    let again = await service.process(failed)
    XCTAssertEqual(again.state, .failed)
    let validBooks = try await repository.books()
    XCTAssertEqual(validBooks.count, 1)
  }
  func testEPUBRoundTripMetadataAndOriginalBytes() async throws {
    let repository = try store()
    let service = ImportService(repository: repository)
    let source = try text("有 & 无.txt")
    let queued = try await service.enqueue(source: source)
    let done = await service.process(queued)
    XCTAssertEqual(done.state, .completed)
    let book = try await repository.books().first!
    let original = try repository.paths.url(book.originalPath)
    XCTAssertEqual(try Data(contentsOf: original), try Data(contentsOf: source))
    let metadata = try await EbookArchive.metadata(at: repository.paths.url(book.readingPath))
    XCTAssertEqual(metadata.title, "有 & 无")
    let epub = try repository.paths.url(book.readingPath)
    let epubJob = try await service.enqueue(source: epub)
    let epubResult = await service.process(epubJob)
    XCTAssertEqual(epubResult.state, .completed)
  }
  func testBackupRestoreIncludesOverridesNotesAndSettings() async throws {
    let repository = try store()
    let service = ImportService(repository: repository)
    let folder = LibraryFolder(title: "我的书")
    try await repository.saveFolder(folder)
    let queued = try await service.enqueue(source: text(), folderID: folder.id)
    _ = await service.process(queued)
    var book = try await repository.books().first!
    book.customTitle = "私人标题"
    book.customCoverPath = try await repository.storeCover(Data([1, 2, 3]))
    try await repository.update(book)
    let annotation = Annotation(
      bookID: book.id, kind: .note, position: .init(locatorJSON: "{}"), quote: "你好", note: "记住这句话")
    try await repository.saveAnnotation(annotation)
    var preferences = ReaderPreferences()
    preferences.theme = .paper
    try await repository.savePreferences(preferences)
    let backup = scratch.appendingPathComponent("书库.miolib")
    try await repository.exportBackup(to: backup)
    let other = try store("Other")
    try await other.restoreBackup(from: backup)
    let books = try await other.books()
    XCTAssertEqual(books.first?.title, "私人标题")
    let notes = try await other.annotations()
    XCTAssertEqual(notes, [annotation])
    let settings = try await other.preferences()
    XCTAssertEqual(settings.theme, .paper)
    let restoredBook = books[0]
    XCTAssertEqual(
      try Data(contentsOf: other.paths.url(restoredBook.customCoverPath!)), Data([1, 2, 3]))
    let before = try await other.books()
    let invalid = try text("损坏.miolib", body: "bad backup")
    do {
      try await other.restoreBackup(from: invalid)
      XCTFail("应拒绝损坏备份")
    } catch {}
    let after = try await other.books()
    XCTAssertEqual(before, after)
  }
  func testInterruptedJobsRecoverAndInvalidPathsReject() async throws {
    let repository = try store()
    let service = ImportService(repository: repository)
    var job = try await service.enqueue(source: text())
    job.state = .processing
    try await repository.saveJob(job)
    try await repository.recoverInterruptedJobs()
    let recovered = try await repository.jobs()
    XCTAssertEqual(recovered.first?.state, .failed)
    for path in ["../outside", "/absolute", "Assets/../../bad", "C:\\bad"] {
      XCTAssertThrowsError(try EbookArchive.validatePath(path))
    }
  }
}
