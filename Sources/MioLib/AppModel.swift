import MioLibCore
import SwiftUI
import UniformTypeIdentifiers

// 主线程只维护界面状态，实际文件和数据库操作交给独立 actor。
@MainActor final class AppModel: ObservableObject {
  @Published var books: [Book] = []
  @Published var folders: [LibraryFolder] = []
  @Published var notes: [Annotation] = []
  @Published var jobs: [ImportJob] = []
  @Published var preferences = ReaderPreferences()
  @Published var readerBook: Book?
  @Published var requestedAnnotation: Annotation?
  @Published var message: String?
  @Published var importPresented = false
  @Published var processing = false
  @Published var maintenance = false
  @Published var sharedItems: ShareItems?
  @Published var pendingBackup: URL?
  @Published var undoIDs: Set<UUID> = []
  let repository: LibraryRepository?
  private let importer: ImportService?
  private let calibreUSB: CalibreUSBReceiver?
  private var receivingCalibreUSB = false
  private var libraryReady = false
  private var queueTask: Task<Void, Never>?
  private var preferenceTask: Task<Void, Never>?
  private var usbSources: [UUID: URL] = [:]

  // 创建路径失败时显示恢复说明，而非强制解包导致启动崩溃。
  init() {
    do {
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      let repository = try LibraryRepository(
        root: support.appendingPathComponent("MioLibLibrary", isDirectory: true))
      self.repository = repository
      let importer = ImportService(repository: repository)
      self.importer = importer
      calibreUSB = CalibreUSBReceiver(repository: repository, importer: importer)
      Task {
        do {
          try await repository.recoverInterruptedJobs()
          try await reload(loadPreferences: true)
          libraryReady = true
        } catch { message = error.localizedDescription }
      }
    } catch {
      repository = nil
      importer = nil
      calibreUSB = nil
      message = "书库无法启动：\(error.localizedDescription)"
    }
  }
  var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
  func fileURL(_ path: String?) -> URL? {
    guard let path else { return nil }
    return try? repository?.paths.url(path)
  }
  func folderPath(_ id: UUID?) -> String {
    guard let id else { return "未归类" }
    var labels: [String] = []
    var current: UUID? = id
    var seen: Set<UUID> = []
    while let value = current, seen.insert(value).inserted,
      let folder = folders.first(where: { $0.id == value })
    {
      labels.insert(folder.title, at: 0)
      current = folder.parentID
    }
    return labels.joined(separator: " / ")
  }
  func reload(loadPreferences: Bool = false) async throws {
    guard let repository else { return }
    let nextBooks = try await repository.books()
    let nextFolders = try await repository.folders()
    let nextJobs = try await repository.jobs()
    let ids = Set(nextBooks.map(\.id))
    let nextNotes = try await repository.annotations().filter { ids.contains($0.bookID) }
    if books != nextBooks { books = nextBooks }
    if folders != nextFolders { folders = nextFolders }
    if jobs != nextJobs { jobs = nextJobs }
    if notes != nextNotes { notes = nextNotes }
    if loadPreferences {
      let settings = try await repository.preferences()
      if settings != preferences { preferences = settings }
    }
  }
  func run(_ operation: @escaping (LibraryRepository) async throws -> Void) {
    guard let repository else { return }
    Task {
      do {
        try await operation(repository)
        try await reload()
      } catch { message = error.localizedDescription }
    }
  }

  // 文件访问在安全作用域内完成；系统协调器负责与来源 App 协调读取。
  func importURLs(_ urls: [URL], folderID: UUID? = nil, usb: Bool = false, encoding: String? = nil)
  {
    guard let importer, !maintenance else { return }
    importPresented = true
    Task {
      for url in urls {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
          let coordinated = try await Task.detached(priority: .utility) {
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
              UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
              at: destination, withIntermediateDirectories: true)
            let copy = destination.appendingPathComponent(url.lastPathComponent)
            var coordinatorError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(
              readingItemAt: url, options: .withoutChanges, error: &coordinatorError
            ) { readable in
              do { try FileManager.default.copyItem(at: readable, to: copy) } catch {
                copyError = error
              }
            }
            if let error = coordinatorError ?? copyError as NSError? {
              try? FileManager.default.removeItem(at: destination)
              throw error
            }
            return copy
          }.value
          defer { try? FileManager.default.removeItem(at: coordinated.deletingLastPathComponent()) }
          let job = try await importer.enqueue(
            source: coordinated, folderID: folderID, encoding: encoding)
          if usb { usbSources[job.id] = url }
          try await reload()
          startQueue()
        } catch { message = "\(url.lastPathComponent)：\(error.localizedDescription)" }
      }
    }
  }
  func receive(_ url: URL) {
    if url.pathExtension.lowercased() == "miolib" { pendingBackup = url } else { importURLs([url]) }
  }
  // Calibre 已完整下载的本地文件直接进入原有队列，沿用去重、转换与失败重试。
  func enqueueCalibreDownload(_ url: URL, folderID: UUID?) async throws {
    guard let importer, !maintenance else { throw LibraryError.message("书库正在维护，请稍后重试") }
    _ = try await importer.enqueue(source: url, folderID: folderID)
    try await reload()
    startQueue()
  }
  // 前台轮询只检查插件完成的书籍；自动导入开关和目标书架均可在 USB 页面修改。
  func receiveCalibreUSB() async {
    guard libraryReady, !maintenance, !receivingCalibreUSB, let calibreUSB,
      (UserDefaults.standard.object(forKey: "calibre.usbAutomatic") as? Bool) ?? true else { return }
    receivingCalibreUSB = true
    defer { receivingCalibreUSB = false }
    let wanted = UserDefaults.standard.string(forKey: "calibre.usbFolder").flatMap(UUID.init(uuidString:))
    let folder = folders.contains(where: { $0.id == wanted }) ? wanted : nil
    do {
      let result = try await calibreUSB.scan(documents: documents, folderID: folder)
      if result.queued > 0 {
        try await reload()
        startQueue()
      }
      if !result.errors.isEmpty { message = result.errors.prefix(3).joined(separator: "\n") }
    } catch is CancellationError {} catch { message = error.localizedDescription }
  }
  func startQueue() {
    guard queueTask == nil, let importer, !maintenance else { return }
    processing = true
    queueTask = Task {
      defer {
        processing = false
        queueTask = nil
      }
      while !Task.isCancelled, let job = jobs.first(where: { $0.state == .queued }) {
        var visible = job
        visible.state = .processing
        visible.detail = "正在解析或转换"
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = visible }
        let result = await importer.process(job)
        // USB 源文件仅在内容仍与已入库原书一致时删除。
        if [.completed, .duplicate].contains(result.state),
          let source = usbSources.removeValue(forKey: job.id), let bookID = result.bookID,
          let repository,
          let book = try? await repository.book(bookID)
        {
          let matches = await Task.detached(priority: .utility) {
            (try? FileFingerprint.hash(file: source)) == book.fingerprint
          }.value
          if matches { try? FileManager.default.removeItem(at: source) }
        }
        do { try await reload() } catch {
          message = error.localizedDescription
          break
        }
      }
    }
  }
  func cancelImports() {
    queueTask?.cancel()
    run { repository in
      for var job in try await repository.jobs() where job.state == .queued {
        job.state = .cancelled
        job.detail = "已取消，可重试"
        try await repository.saveJob(job)
      }
    }
  }
  func retry(_ job: ImportJob, encoding: String? = nil) {
    guard let repository else { return }
    Task {
      do {
        var next = job
        next.state = .queued
        next.detail = "等待重试"
        if let encoding { next.encoding = encoding }
        try await repository.saveJob(next)
        try await reload()
        startQueue()
      } catch { message = error.localizedDescription }
    }
  }
  func usbFiles() async -> [URL] {
    let directory = documents
    return await Task.detached(priority: .utility) {
      guard
        let enumerator = FileManager.default.enumerator(
          at: directory, includingPropertiesForKeys: [.isRegularFileKey],
          options: [.skipsHiddenFiles, .skipsPackageDescendants])
      else { return [] }
      var files: [URL] = []
      for case let url as URL in enumerator {
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
          (try? BookFormat.detect(url)) != nil
        {
          files.append(url)
        }
      }
      return files.sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
      }
    }.value
  }

  // 阅读偏好延迟写入，滑动字号控制时不连续触发磁盘写入。
  func changePreferences(_ value: ReaderPreferences) {
    preferences = value
    preferenceTask?.cancel()
    preferenceTask = Task {
      do {
        try await Task.sleep(for: .milliseconds(250))
        try Task.checkCancellation()
        try await repository?.savePreferences(value)
      } catch is CancellationError {} catch { message = error.localizedDescription }
    }
  }
  // 进入后台前立刻落盘，覆盖用户选完排序后马上离开应用的情况。
  func flushPreferences() async {
    guard libraryReady else { return }
    preferenceTask?.cancel()
    do { try await repository?.savePreferences(preferences) }
    catch { message = error.localizedDescription }
  }
  func open(_ book: Book, annotation: Annotation? = nil) {
    requestedAnnotation = annotation
    readerBook = book
  }
  func trash(_ ids: Set<UUID>) {
    undoIDs = ids
    run { try await $0.trashBooks(ids) }
  }
  func undoDelete() {
    let ids = undoIDs
    undoIDs = []
    run { try await $0.undoTrash(ids) }
  }
  func exportNotes(bookID: UUID? = nil, markdown: Bool) {
    guard let repository else { return }
    Task {
      do {
        let data = try await repository.noteExport(bookID: bookID, markdown: markdown)
        let url = exportURL(name: "阅读笔记", extension: markdown ? "md" : "json")
        try data.write(to: url, options: .atomic)
        sharedItems = ShareItems(urls: [url])
      } catch { message = error.localizedDescription }
    }
  }
  func backup() {
    guard let repository, !processing, !maintenance else { return }
    maintenance = true
    preferenceTask?.cancel()
    Task {
      defer { maintenance = false }
      do {
        try await repository.savePreferences(preferences)
        let url = exportURL(name: "MioLib书库", extension: "miolib")
        try await repository.exportBackup(to: url)
        sharedItems = ShareItems(urls: [url])
      } catch { message = error.localizedDescription }
    }
  }
  func restore(_ url: URL) {
    guard let repository, !processing, !maintenance else { return }
    maintenance = true
    preferenceTask?.cancel()
    pendingBackup = nil
    Task {
      let access = url.startAccessingSecurityScopedResource()
      defer {
        if access { url.stopAccessingSecurityScopedResource() }
        maintenance = false
      }
      do {
        try await repository.restoreBackup(from: url)
        try await reload(loadPreferences: true)
        message = "书库恢复完成"
      } catch { message = error.localizedDescription }
    }
  }
  func exportURL(name: String, extension ext: String) -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Exports", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6)).\(ext)")
  }
}

// 分享使用系统面板，文件 URL 在面板关闭前保持有效。
struct ShareItems: Identifiable {
  let id = UUID()
  let urls: [URL]
}
struct ShareSheet: UIViewControllerRepresentable {
  let items: [URL]
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: items, applicationActivities: nil)
  }
  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// 自有与导入类型统一提供给系统文件选择器。
extension UTType {
  static let mioBackup = UTType(exportedAs: "com.miolib.backup", conformingTo: .zip)
  static var mioBooks: [UTType] {
    [
      .epub, .plainText, .pdf, UTType(importedAs: "com.miolib.mobi"),
      UTType(importedAs: "com.miolib.azw3"),
    ]
  }
}
