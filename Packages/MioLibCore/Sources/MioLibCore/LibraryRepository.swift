import Foundation

// 所有写入在一个 actor 内排队，界面只接收不可变快照。
public actor LibraryRepository {
  public nonisolated let paths: LibraryPaths
  let database: SQLiteDatabase
  var maintenance = false
  // 正在使用的阅读副本由阅读器持有，缓存换包后延迟回收旧文件。
  var activeWebReadingPaths: [String: Int] = [:]
  var retiredWebReadingPaths: Set<String> = []
  public init(root: URL) throws {
    paths = try LibraryPaths(root: root)
    database = try SQLiteDatabase(url: root.appendingPathComponent("library.sqlite"))
  }
  func writable() throws {
    if maintenance { throw LibraryError.message("书库正在备份或恢复，请稍后再试") }
  }
  public func books(includeDeleted: Bool = false) throws -> [Book] {
    try database.data("SELECT payload FROM books").map {
      try LibraryJSON.decode(Book.self, from: $0)
    }
    .filter { includeDeleted || $0.deletedAt == nil }
  }
  public func folders() throws -> [LibraryFolder] {
    try database.data("SELECT payload FROM folders").map {
      try LibraryJSON.decode(LibraryFolder.self, from: $0)
    }
  }
  public func annotations(bookID: UUID? = nil) throws -> [Annotation] {
    let records =
      try bookID.map {
        try database.data("SELECT payload FROM annotations WHERE book_id=?", [.text($0.uuidString)])
      }
      ?? database.data("SELECT payload FROM annotations")
    return try records.map { try LibraryJSON.decode(Annotation.self, from: $0) }.sorted {
      $0.createdAt > $1.createdAt
    }
  }
  public func jobs() throws -> [ImportJob] {
    try database.data("SELECT payload FROM jobs ORDER BY rowid").map {
      try LibraryJSON.decode(ImportJob.self, from: $0)
    }
  }
  // 稳定 USB 任务 ID 通过主键查询，避免重复接收覆盖已保存的失败或取消状态。
  public func job(_ id: UUID) throws -> ImportJob? {
    guard let data = try database.data("SELECT payload FROM jobs WHERE id=?", [.text(id.uuidString)]).first
    else { return nil }
    return try LibraryJSON.decode(ImportJob.self, from: data)
  }
  public func preferences() throws -> ReaderPreferences {
    guard let data = try database.data("SELECT payload FROM settings WHERE id='preferences'").first
    else { return ReaderPreferences() }
    return try LibraryJSON.decode(ReaderPreferences.self, from: data)
  }

  // 书籍的散列唯一约束同时保护多个导入入口的去重结果。
  public func insert(_ book: Book) throws {
    try writable()
    if let existing = try existingBook(fingerprint:book.fingerprint) {
      if existing.deletedAt != nil {
        var restored = existing
        restored.deletedAt = nil
        try putBook(restored)
      }
      throw LibraryError.duplicate(existing.id)
    }
    if let folder = book.folderID, !((try folders()).contains { $0.id == folder }) {
      throw LibraryError.message("目标书架已被删除，请重新选择")
    }
    try putBook(book)
  }

  // 利用散列唯一索引，批量导入不再逐本解码整个书库。
  public func existingBook(fingerprint:String)throws->Book?{
    guard let data=try database.data("SELECT payload FROM books WHERE hash=?",[.text(fingerprint)]).first else{return nil}
    return try LibraryJSON.decode(Book.self,from:data)
  }

  // 书籍与完成记录同时提交，避免写入记录失败后错误回收已入库的文件。
  public func commitImport(_ book: Book, job: ImportJob) throws {
    try writable()
    try database.transaction {
      try insert(book)
      try saveJob(job)
    }
  }
  func putBook(_ book: Book) throws {
    try database.run(
      "INSERT INTO books(id,folder_id,hash,payload) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET folder_id=excluded.folder_id,hash=excluded.hash,payload=excluded.payload",
      [
        .text(book.id.uuidString), book.folderID.map { .text($0.uuidString) } ?? .null,
        .text(book.fingerprint), .blob(try LibraryJSON.encode(book)),
      ])
  }
  public func book(_ id: UUID) throws -> Book {
    guard
      let data = try database.data("SELECT payload FROM books WHERE id=?", [.text(id.uuidString)])
        .first
    else {
      throw LibraryError.message("书籍不存在")
    }
    return try LibraryJSON.decode(Book.self, from: data)
  }
  public func update(_ book: Book) throws {
    try writable()
    _ = try self.book(book.id)
    try putBook(book)
  }
  public func updateProgress(bookID: UUID, position: ReadingPosition, progress: Double,
    webSourcePath: String? = nil) throws
  {
    try writable()
    var book = try book(bookID)
    // 仍打开旧副本的阅读器可以翻阅，但不能把已删除的章写回当前进度。
    if let webSourcePath {
      guard book.originalPath == webSourcePath, let href = position.webResourceHref,
        book.cachedWebChapters.contains(where: { $0.href == href }) else { return }
    }
    book.position = position
    book.progress = ReadingProgress.normalized(progress)
    book.lastOpenedAt = Date()
    try putBook(book)
  }
  public func moveBooks(_ ids: Set<UUID>, to folderID: UUID?) throws {
    try writable()
    if let folderID, !((try folders()).contains { $0.id == folderID }) {
      throw LibraryError.message("目标书架不存在")
    }
    try database.transaction {
      for id in ids {
        var book = try book(id)
        book.folderID = folderID
        try putBook(book)
      }
    }
  }
  // 批量编辑以事务提交，任一本书或目标目录失效时整批回滚，阅读位置和自定义封面保留。
  public func batchEditBooks(_ ids: Set<UUID>, favorite: Bool? = nil, finished: Bool? = nil,
    move: Bool = false, folderID: UUID? = nil) throws
  {
    try writable()
    if move, let folderID, !((try folders()).contains { $0.id == folderID }) {
      throw LibraryError.message("目标书架不存在")
    }
    try database.transaction {
      for id in ids {
        var book = try book(id)
        guard book.deletedAt == nil else { throw LibraryError.message("所选书籍已被删除，请重新选择") }
        if let favorite { book.isFavorite = favorite }
        if let finished { book.isFinished = finished }
        if move { book.folderID = folderID }
        try putBook(book)
      }
    }
  }
  // 封面与标题按书籍 ID 更新最新记录，阅读中设置封面不会覆盖刚保存的进度。
  public func updateBookMetadata(_ id: UUID, title: String? = nil,
    coverData: Data? = nil, resetCover: Bool = false, webAddress: String? = nil) throws
  {
    try writable()
    var value = try book(id)
    guard value.deletedAt == nil else { throw LibraryError.message("书籍已被删除") }
    let oldWebAssets = value.format == .web ? Set(value.assetPaths) : []
    if let title {
      let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { throw LibraryError.message("书名不能为空") }
      value.customTitle = trimmed == value.originalTitle ? nil : trimmed
    }
    var created: String?
    var newLink: String?
    do {
      // 改链后旧正文和定位不再适用；笔记文字、原书籍 ID、收藏和所在书架保留。
      if let webAddress {
        guard value.format == .web else { throw LibraryError.message("只有网页书籍可以修改链接") }
        let url = try WebAddress.url(webAddress)
        if url != value.webURL {
          let fingerprint = Self.webFingerprint(url)
          if let duplicate = try existingBook(fingerprint: fingerprint), duplicate.id != id {
            throw LibraryError.message("书架中已有此网址的书籍")
          }
          let linkPath = try storeWebLink(url)
          newLink = linkPath
          value.webURL = url
          value.fingerprint = fingerprint
          value.author = url.host ?? ""
          value.originalPath = linkPath
          value.readingPath = linkPath
          value.webSnapshotDate = nil
          value.webChapters = nil
          value.webPendingChapters = nil
          value.webCacheCompleted = nil
          // 卷选择和已删章节的定位属于原链接，改链接后重新分析目录。
          value.webVolumes = nil
          value.webVolumeIDs = nil
          value.webCacheRevision = nil
          value.webRemovedChapterPrefixes = nil
          value.position = nil
          value.progress = 0
          value.isFinished = false
        }
      }
      if let coverData {
        created = try storeCover(coverData)
        value.customCoverPath = created
      } else if resetCover { value.customCoverPath = nil }
      // 取消失效的笔记定位和改链在同一个事务内提交，摘录、批注和颜色继续保留。
      try database.transaction {
        try putBook(value)
        if newLink != nil {
          for var note in try annotations(bookID: id) {
            note.position = ReadingPosition()
            try saveAnnotation(note)
          }
        }
      }
      // 仅在改链提交成功后回收旧的独占文件，其他书籍、封面或个人资料的引用优先保留。
      if newLink != nil { removeUnusedWebAssets(oldWebAssets) }
    } catch {
      if let created { try? FileManager.default.removeItem(at: paths.url(created)) }
      if let newLink { try? FileManager.default.removeItem(at: paths.url(newLink)) }
      throw error
    }
  }
  public func trashBooks(_ ids: Set<UUID>) throws {
    try writable()
    try database.transaction {
      for id in ids {
        var book = try book(id)
        book.deletedAt = Date()
        try putBook(book)
      }
    }
  }
  public func undoTrash(_ ids: Set<UUID>) throws {
    try writable()
    try database.transaction {
      for id in ids {
        var book = try book(id)
        book.deletedAt = nil
        try putBook(book)
      }
    }
  }

  // 书架名称按同级去重；祖先遍历同时阻止自移和循环嵌套。
  public func saveFolder(_ folder: LibraryFolder) throws {
    try writable()
    var folder = folder
    folder.title = folder.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !folder.title.isEmpty, folder.title.count <= 80 else {
      throw LibraryError.message("书架名称需为 1～80 个字")
    }
    let all = try folders()
    if all.contains(where: {
      $0.id != folder.id && $0.parentID == folder.parentID
        && $0.title.localizedCaseInsensitiveCompare(folder.title) == .orderedSame
    }) {
      throw LibraryError.message("同级已有同名书架")
    }
    var parent = folder.parentID
    var visited: Set<UUID> = [folder.id]
    while let id = parent {
      guard visited.insert(id).inserted else { throw LibraryError.message("不能将书架移入自身或其子书架") }
      guard let ancestor = all.first(where: { $0.id == id }) else {
        throw LibraryError.message("上级书架不存在")
      }
      parent = ancestor.parentID
    }
    try putFolder(folder)
  }
  func putFolder(_ folder: LibraryFolder) throws {
    try database.run(
      "INSERT INTO folders(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
      [.text(folder.id.uuidString), .blob(try LibraryJSON.encode(folder))])
  }
  public func descendantIDs(of id: UUID) throws -> Set<UUID> {
    let all = try folders()
    var result: Set<UUID> = [id]
    var changed = true
    while changed {
      changed = false
      for folder in all where folder.parentID.map(result.contains) == true {
        if result.insert(folder.id).inserted { changed = true }
      }
    }
    return result
  }
  public func deleteFolder(_ id: UUID) throws {
    try writable()
    let ids = try descendantIDs(of: id)
    try database.transaction {
      for var book in try books(includeDeleted: true) where book.folderID.map(ids.contains) == true
      {
        book.folderID = nil
        try putBook(book)
      }
      for folder in ids {
        try database.run("DELETE FROM folders WHERE id=?", [.text(folder.uuidString)])
      }
    }
  }

  // 标注、导入任务和偏好均通过同一个存储入口保持可恢复性。
  public func saveAnnotation(_ annotation: Annotation) throws {
    try writable()
    _ = try book(annotation.bookID)
    try database.run(
      "INSERT INTO annotations(id,book_id,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
      [
        .text(annotation.id.uuidString), .text(annotation.bookID.uuidString),
        .blob(try LibraryJSON.encode(annotation)),
      ])
  }
  public func deleteAnnotation(_ id: UUID) throws {
    try writable()
    try database.run("DELETE FROM annotations WHERE id=?", [.text(id.uuidString)])
  }
  public func saveJob(_ job: ImportJob) throws {
    try writable()
    try database.run(
      "INSERT INTO jobs(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
      [.text(job.id.uuidString), .blob(try LibraryJSON.encode(job))])
  }
  public func recoverInterruptedJobs() throws {
    try writable()
    for var job in try jobs() where job.state == .processing {
      job.state = .failed
      job.detail = "上次导入已中断，可点击重试"
      try saveJob(job)
    }
  }
  public func clearCompletedJobs() throws {
    try writable()
    // 已取消任务保留重试状态，避免清理记录后 USB 接收器把同一传书重新排队。
    for job in try jobs() where [.completed, .duplicate].contains(job.state) {
      try database.run("DELETE FROM jobs WHERE id=?", [.text(job.id.uuidString)])
      if let url = try? paths.url(job.stagedPath) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
      }
    }
  }
  public func savePreferences(_ preferences: ReaderPreferences) throws {
    try writable()
    try putPreferences(preferences)
  }
  func putPreferences(_ preferences: ReaderPreferences) throws {
    try database.run(
      "INSERT INTO settings(id,payload) VALUES('preferences',?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
      [.blob(try LibraryJSON.encode(preferences))])
  }

  // 封面使用新文件名写入，图片替换失败时数据库仍指向之前的封面。
  public func storeCover(_ data: Data) throws -> String {
    try writable()
    guard data.count <= 20 * 1024 * 1024 else {
      throw LibraryError.message("封面图片过大，请选择小于 20 MB 的图片")
    }
    let relative = "Covers/\(UUID().uuidString).jpg"
    try data.write(to: paths.url(relative), options: .atomic)
    return relative
  }
  // 个人资料读取最新偏好后再修改，头像与资料一起提交，避免覆盖书架排序或阅读设置。
  public func updateProfile(name: String, bio: String, avatarData: Data? = nil,
                            resetAvatar: Bool = false) throws -> ReaderPreferences {
    try writable()
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 40, bio.count <= 300 else {
      throw LibraryError.message("昵称请填写 1～40 个字，个人简介不超过 300 个字")
    }
    var prefs = try preferences()
    let oldAvatar = prefs.profileAvatarPath
    let newAvatar = try avatarData.map { try storeCover($0) }
    prefs.profileName = name
    prefs.profileBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
    if let newAvatar { prefs.profileAvatarPath = newAvatar }
    else if resetAvatar { prefs.profileAvatarPath = nil }
    do { try savePreferences(prefs) }
    catch {
      if let newAvatar { try? FileManager.default.removeItem(at: paths.url(newAvatar)) }
      throw error
    }
    // 只回收本次替换的头像文件；其他书籍和封面资源不受影响。
    if let oldAvatar, oldAvatar != prefs.profileAvatarPath {
      let bookReferences = try? books(includeDeleted: true).flatMap(\.assetPaths)
      let folderReferences = try? folders().compactMap(\.coverPath)
      if let bookReferences, let folderReferences,
         !bookReferences.contains(oldAvatar) && !folderReferences.contains(oldAvatar) {
        try? FileManager.default.removeItem(at: paths.url(oldAvatar))
      }
    }
    return prefs
  }
  public func noteExport(bookID: UUID?, markdown: Bool) throws -> Data {
    let allBooks = try books()
    let byID = Dictionary(uniqueKeysWithValues: allBooks.map { ($0.id, $0) })
    let notes = try annotations(bookID: bookID).filter { byID[$0.bookID] != nil }
    if !markdown { return try LibraryJSON.encode(notes) }
    var text = "# MioLib 阅读笔记\n\n"
    for note in notes {
      text += "## \(byID[note.bookID]?.title ?? "")\n\n"
      if !note.chapter.isEmpty { text += "位置：\(note.chapter)\n\n" }
      if !note.quote.isEmpty {
        text +=
          note.quote.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
          + "\n\n"
      }
      if !note.note.isEmpty { text += note.note + "\n\n" }
      text += "---\n\n"
    }
    return Data(text.utf8)
  }
}
