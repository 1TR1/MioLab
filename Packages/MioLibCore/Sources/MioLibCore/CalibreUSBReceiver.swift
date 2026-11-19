import Foundation

// Calibre 插件最后原子提交此清单；没有清单的目录始终视为尚未传完。
public struct CalibreUSBManifest: Codable, Sendable {
  public var version: Int
  public var id: UUID
  public var filename: String
  public var title: String
  public var author: String
  public var bytes: Int
  public var sha256: String
  public init(id: UUID, filename: String, title: String, author: String, bytes: Int, sha256: String) {
    version = 1
    self.id = id
    self.filename = filename
    self.title = title
    self.author = author
    self.bytes = bytes
    self.sha256 = sha256
  }
}
public struct CalibreUSBResult: Sendable {
  public var queued = 0
  public var errors: [String] = []
}

// 接收器仅查看插件专用目录，手动复制到 Documents 的其他文件仍由原来的 USB 页面管理。
public actor CalibreUSBReceiver {
  private let repository: LibraryRepository
  private let importer: ImportService
  private var scanning = false
  private var reported: Set<URL> = []
  public init(repository: LibraryRepository, importer: ImportService) {
    self.repository = repository
    self.importer = importer
  }
  public func scan(documents: URL, folderID: UUID? = nil) async throws -> CalibreUSBResult {
    guard !scanning else { return CalibreUSBResult() }
    scanning = true
    defer { scanning = false }
    let root = documents.appendingPathComponent(".CalibreUSB", isDirectory: true)
    guard FileManager.default.fileExists(atPath: root.path) else { return CalibreUSBResult() }
    try plainItem(root, directory: true)
    let directories = try FileManager.default.contentsOfDirectory(at: root,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
    guard !directories.isEmpty else { return CalibreUSBResult() }
    let existing = Dictionary(uniqueKeysWithValues: try await repository.jobs().map { ($0.id, $0) })
    var result = CalibreUSBResult()
    for directory in directories {
      if Task.isCancelled { break }
      guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
      let manifestURL = directory.appendingPathComponent("transfer.json")
      guard FileManager.default.fileExists(atPath: manifestURL.path), !reported.contains(manifestURL) else { continue }
      do {
        // 固定文件名、UUID 和普通文件检查共同阻止目录穿越、符号链接和伪造超大输入。
        try plainItem(directory, directory: true)
        try plainItem(manifestURL, directory: false, maximum: 32 * 1024)
        let manifest = try JSONDecoder().decode(CalibreUSBManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.version == 1, manifest.id == id,
          manifest.bytes > 0, manifest.bytes <= 512 * 1024 * 1024,
          manifest.title.utf8.count <= 8192, manifest.author.utf8.count <= 8192,
          manifest.sha256.count == 64,
          manifest.sha256.unicodeScalars.allSatisfy({ "0123456789abcdef".unicodeScalars.contains($0) }),
          let format = BookFormat(rawValue: URL(fileURLWithPath: manifest.filename).pathExtension), format != .web,
          manifest.filename == "book.\(format.rawValue)"
        else { throw LibraryError.message("Calibre USB 传书清单无效，请重新发送") }
        let source = directory.appendingPathComponent(manifest.filename)
        try plainItem(source, directory: false, maximum: 512 * 1024 * 1024)
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == manifest.bytes else { throw LibraryError.message("USB 书籍大小不符，请从 Calibre 重新发送") }
        if let job = existing[id] {
          guard job.sourceFingerprint == manifest.sha256 else { throw LibraryError.message("USB 任务标识冲突") }
          // 成功后才清理这份传输副本；失败、取消及重启后的任务保留原来的重试状态。
          if [.completed, .duplicate].contains(job.state),
            try FileFingerprint.hash(file: source) == manifest.sha256 {
            try FileManager.default.removeItem(at: source)
            try FileManager.default.removeItem(at: manifestURL)
            if try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty {
              try FileManager.default.removeItem(at: directory)
            }
          }
          continue
        }
        _ = try await importer.enqueue(source: source, folderID: folderID, jobID: id,
          title: manifest.title.isEmpty ? "Calibre 书籍" : manifest.title,
          author: manifest.author, fingerprint: manifest.sha256)
        result.queued += 1
      } catch is CancellationError { return result }
      catch {
        reported.insert(manifestURL)
        result.errors.append(error.localizedDescription)
      }
    }
    return result
  }

  // 只接受此目录内的普通文件，不跟随文件共享区中的符号链接。
  private func plainItem(_ url: URL, directory: Bool, maximum: Int = 0) throws {
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
    guard values.isSymbolicLink != true,
      (directory ? values.isDirectory == true : values.isRegularFile == true)
    else { throw LibraryError.message("USB 传书路径不是预期的普通文件或文件夹") }
    if !directory, (values.fileSize ?? Int.max) > maximum {
      throw LibraryError.message("USB 传入文件超过允许大小")
    }
  }
}
