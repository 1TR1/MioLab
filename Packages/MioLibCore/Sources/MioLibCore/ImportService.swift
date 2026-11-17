import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

// 单队列处理导入任务；文件准备与解析均离开主线程，逐本失败可单独重试。
public actor ImportService {
  public let repository: LibraryRepository
  private var enqueuing: Set<UUID> = []
  public init(repository: LibraryRepository) { self.repository = repository }

  // 来源文件先进入独立暂存目录，外部 App 的临时 URL 失效也不影响重试。
  public func enqueue(source: URL, folderID: UUID? = nil, encoding: String? = nil,
    jobID: UUID = UUID(), title: String? = nil, author: String? = nil, fingerprint: String? = nil) async throws
    -> ImportJob
  {
    // actor 在等待数据库时允许重入，同一个稳定传输 ID 只能有一次暂存写入。
    guard enqueuing.insert(jobID).inserted else { throw LibraryError.message("此传输正在接收") }
    defer { enqueuing.remove(jobID) }
    _ = try BookFormat.detect(source)
    let values = try source.resourceValues(forKeys: [
      .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
    ])
    guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
      throw LibraryError.message("文件为空、仍在复制，或不是普通文件")
    }
    guard size <= 512 * 1024 * 1024 else { throw LibraryError.message("单本书不能超过 512 MB，请先分卷") }
    let id = jobID
    let directory = "Staging/\(id.uuidString)"
    let name = source.lastPathComponent
    let path = "\(directory)/\(name)"
    let destination = try repository.paths.url(path)
    // 崩溃发生在复制完成与任务持久化之间时，仅回收没有数据库记录的孤立暂存目录。
    guard try await repository.job(id) == nil else { throw LibraryError.message("此传输任务已存在") }
    if FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path) {
      try FileManager.default.removeItem(at: destination.deletingLastPathComponent())
    }
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
      try Task.checkCancellation()
      try FileManager.default.copyItem(at: source, to: destination)
      let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      guard after.fileSize == size, after.contentModificationDate == values.contentModificationDate
      else {
        throw LibraryError.message("文件仍在传输，请等待 USB 复制完成后重试")
      }
      var job = ImportJob(
        id: id, name: title.map { $0 + "." + source.pathExtension } ?? name,
        stagedPath: path, folderID: folderID, encoding: encoding)
      job.sourceTitle = title
      job.sourceAuthor = author
      job.sourceFingerprint = fingerprint
      try await repository.saveJob(job)
      return job
    } catch {
      try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
      throw error
    }
  }

  // 只有数据库提交成功才报告完成；生成的中间文件在失败或取消时回收。
  public func process(_ input: ImportJob) async -> ImportJob {
    var job = input
    job.state = .processing
    job.detail = "正在校验文件"
    var created: [URL] = []
    do {
      try await repository.saveJob(job)
      try Task.checkCancellation()
      let source = try repository.paths.url(job.stagedPath)
      let format = try BookFormat.detect(source)
      let hash = try FileFingerprint.hash(file: source)
      // Calibre USB 的完成清单提供原始摘要，损坏或被替换的文件不能进入正式书库。
      if let expected = job.sourceFingerprint, expected != hash {
        throw LibraryError.message("USB 文件校验失败，请从 Calibre 重新发送此书")
      }
      if let existing = try await repository.existingBook(fingerprint:hash) {
        if existing.deletedAt != nil { try await repository.undoTrash([existing.id]) }
        job.state = .duplicate
        job.detail = "书库已有相同文件"
        job.bookID = existing.id
        try await repository.saveJob(job)
        return job
      }
      let id = UUID()
      let original = "Originals/\(id.uuidString).\(format.rawValue)"
      let originalURL = try repository.paths.url(original)
      let reading = (format == .epub || format == .pdf) ? original : "Reading/\(id.uuidString).epub"
      let readingURL = try repository.paths.url(reading)
      let fallback = job.sourceTitle ?? source.deletingPathExtension().lastPathComponent
      var title = fallback
      var author = ""
      var cover: Data?
      if format == .txt || format == .mobi || format == .azw3 {
        job.detail = "正在生成离线阅读副本"
        try await repository.saveJob(job)
        created.append(readingURL)
        if format == .txt {
          try await TextBookConverter.convert(
            source: source, destination: readingURL, title: fallback, encoding: job.encoding)
        } else {
          try await KindleBookConverter.convert(source: source, destination: readingURL)
        }
      }
      if format != .pdf {
        let metadata = try await EbookArchive.metadata(at: format == .epub ? source : readingURL)
        if !metadata.title.isEmpty { title = metadata.title }
        author = metadata.author
        cover = metadata.cover
      } else {
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        guard let header = try file.read(upToCount: 1024),
          String(decoding: header, as: UTF8.self).contains("%PDF-")
        else {
          throw LibraryError.message("文件不是有效的 PDF")
        }
        // Apple 平台进一步验证页面结构，拒绝加密或仅伪造文件头的 PDF。
        #if canImport(PDFKit)
          guard let document=PDFDocument(url:source),document.pageCount>0,!document.isLocked else {
            throw LibraryError.message("PDF 已损坏、加密或没有页面")
          }
          if let attributes=document.documentAttributes {
            if let supplied=attributes[PDFDocumentAttribute.titleAttribute] as? String,!supplied.isEmpty {title=supplied}
            author=attributes[PDFDocumentAttribute.authorAttribute] as? String ?? ""
          }
          if let first=document.page(at:0){cover=first.thumbnail(of:CGSize(width:280,height:400),for:.cropBox).jpegData(compressionQuality:0.85)}
        #endif
      }
      // 采用 Calibre 的显示书名和作者，原书文件保持逐字节不变。
      if let supplied = job.sourceTitle, !supplied.isEmpty { title = supplied }
      if let supplied = job.sourceAuthor { author = supplied }
      try Task.checkCancellation()
      try FileManager.default.copyItem(at: source, to: originalURL)
      created.append(originalURL)
      var book = Book(
        id: id, title: title, author: author, format: format, originalPath: original,
        readingPath: reading, fingerprint: hash, folderID: job.folderID)
      if let cover {
        let coverPath = try await repository.storeCover(cover)
        book.coverPath = coverPath
        created.append(try repository.paths.url(coverPath))
      }
      try Task.checkCancellation()
      job.state = .completed
      job.detail = "已导入"
      job.bookID = id
      try await repository.commitImport(book,job:job)
    } catch is CancellationError {
      job.state = .cancelled
      job.detail = "已取消，可重试"
      for url in created { try? FileManager.default.removeItem(at: url) }
      try? await repository.saveJob(job)
    } catch LibraryError.duplicate(let id) {
      job.state = .duplicate
      job.detail = "书库已有相同文件"
      job.bookID = id
      for url in created { try? FileManager.default.removeItem(at: url) }
      try? await repository.saveJob(job)
    } catch {
      job.state = .failed
      job.detail = error.localizedDescription
      for url in created { try? FileManager.default.removeItem(at: url) }
      try? await repository.saveJob(job)
    }
    return job
  }
}
