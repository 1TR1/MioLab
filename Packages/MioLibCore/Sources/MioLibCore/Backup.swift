import Foundation
import MioZIPFoundation

// 备份保存逻辑快照而非直接复制 WAL 数据库，版本与文件指纹均可验证。
struct BackupManifest: Codable {
  var version: Int = 2
  var books: [Book]
  var folders: [LibraryFolder]
  var annotations: [Annotation]
  var preferences: ReaderPreferences
  var files: [String: String]
  // 旧版备份没有网页字段；可选字段允许恢复时迁移为默认值。
  var webBookmarks: [WebBookmark]? = nil
  var webPreferences: WebPreferences? = nil
}
extension LibraryRepository {
  // 维护锁跨越异步 ZIP 操作，防止导入、改名或恢复与快照交叉写入。
  public func exportBackup(to destination: URL) async throws {
    try writable()
    maintenance = true
    defer { maintenance = false }
    let books = try books()
    let folders = try folders()
    let ids = Set(books.map(\.id))
    let annotations = try annotations().filter { ids.contains($0.bookID) }
    let preferences = try preferences()
    var references = Set(books.flatMap(\.assetPaths))
    references.formUnion(folders.compactMap(\.coverPath))
    if let avatar = preferences.profileAvatarPath { references.insert(avatar) }
    var hashes: [String: String] = [:]
    for relative in references {
      hashes[relative] = try FileFingerprint.hash(file: paths.url(relative))
    }
    // 网页书籍需要新版解码，普通书库仍可导出原来的版本 2。
    // 有未合并章节的备份也包含这些源文件，恢复后可以继续缓存。
    let version: Int
    // 卷选择与删卷后的笔记定位也需要随备份恢复，旧备份的缺省选择仍为整本。
    if books.contains(where: { $0.webVolumes != nil || $0.webVolumeIDs != nil || $0.webRemovedChapterPrefixes != nil }) {
      version = 6
    } else if books.contains(where: { $0.webPendingChapters != nil }) { version = 5 }
    else if books.contains(where: { $0.webChapters != nil }) { version = 4 }
    else { version = books.contains(where: { $0.format == .web }) ? 3 : 2 }
    let snapshot = BackupManifest(version: version,
      books: books, folders: folders, annotations: annotations, preferences: preferences,
      files: hashes, webBookmarks: try webBookmarks(), webPreferences: try webPreferences())
    do {
      let archive = try await Archive(url: destination, accessMode: .create)
      try await EbookArchive.add(archive, path: "manifest.json", data: LibraryJSON.encode(snapshot))
      for relative in references.sorted() {
        try Task.checkCancellation()
        try await archive.addEntry(
          with: "Assets/" + relative, fileURL: paths.url(relative), compressionMethod: .none)
      }
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }

  // 恢复先解压并逐文件校验，最后用单个数据库事务切换；失败不覆盖现有书库。
  public func restoreBackup(from source: URL) async throws {
    try writable()
    maintenance = true
    defer { maintenance = false }
    let prefix = "Restored/\(UUID().uuidString)"
    let restored = try paths.url(prefix)
    do {
      let archive = try await Archive(url: source, accessMode: .read)
      let entries = try await archive.entries()
      var seen: Set<String> = []
      var total: UInt64 = 0
      guard entries.count <= 100_000 else { throw LibraryError.message("备份条目过多") }
      for entry in entries {
        try EbookArchive.validatePath(entry.path)
        guard seen.insert(entry.path).inserted, entry.type != .symlink,
          entry.path == "manifest.json" || entry.path.hasPrefix("Assets/")
        else { throw LibraryError.message("备份包含重复路径或非法文件") }
        total += entry.uncompressedSize
        guard total <= 64 * 1024 * 1024 * 1024 else { throw LibraryError.message("备份解压大小超出限制") }
      }
      var snapshot = try LibraryJSON.decode(
        BackupManifest.self,
        from: await EbookArchive.read(archive, path: "manifest.json", limit: 64 * 1024 * 1024))
      guard (1...6).contains(snapshot.version) else { throw LibraryError.message("此备份版本暂不支持，请更新 MioLib") }
      try validateSnapshot(snapshot)
      for (relative, hash) in snapshot.files {
        try Task.checkCancellation()
        let newPath = prefix + "/" + relative
        let destination = try paths.url(newPath)
        guard let entry = try await archive.get("Assets/" + relative), entry.type == .file else {
          throw LibraryError.message("备份缺少文件：\(relative)")
        }
        _ = try await archive.extract(entry, to: destination)
        guard try FileFingerprint.hash(file: destination) == hash else {
          throw LibraryError.message("备份文件校验失败：\(relative)")
        }
      }
      let oldBooks = try books(includeDeleted: true)
      let oldFolders = try folders()
      var oldPaths = Set(
        oldBooks.flatMap(\.assetPaths) + oldFolders.compactMap(\.coverPath))
      if let avatar = try preferences().profileAvatarPath { oldPaths.insert(avatar) }
      for index in snapshot.books.indices {
        snapshot.books[index].originalPath = prefix + "/" + snapshot.books[index].originalPath
        snapshot.books[index].readingPath = prefix + "/" + snapshot.books[index].readingPath
        snapshot.books[index].coverPath = snapshot.books[index].coverPath.map { prefix + "/" + $0 }
        snapshot.books[index].customCoverPath = snapshot.books[index].customCoverPath.map {
          prefix + "/" + $0
        }
        // 章节源副本与聚合正文一起迁移，恢复后仍能追加新章或离线回看旧章。
        snapshot.books[index].webChapters = snapshot.books[index].webChapters?.map {
          var chapter = $0
          chapter.readingPath = prefix + "/" + chapter.readingPath
          return chapter
        }
        // 中断时下载的源章节同样重写为恢复后的本地路径。
        snapshot.books[index].webPendingChapters = snapshot.books[index].webPendingChapters?.map {
          var chapter = $0
          chapter.readingPath = prefix + "/" + chapter.readingPath
          return chapter
        }
      }
      for index in snapshot.folders.indices {
        snapshot.folders[index].coverPath = snapshot.folders[index].coverPath.map {
          prefix + "/" + $0
        }
      }
      // 恢复后的头像与书籍资源一样改写路径，避免继续指向旧设备或恢复前的文件。
      snapshot.preferences.profileAvatarPath = snapshot.preferences.profileAvatarPath.map { prefix + "/" + $0 }
      try database.transaction {
        for table in ["annotations", "books", "folders", "jobs", "settings", "web_bookmarks"] {
          try database.run("DELETE FROM \(table)")
        }
        for folder in snapshot.folders { try putFolder(folder) }
        for book in snapshot.books { try putBook(book) }
        for annotation in snapshot.annotations {
          try database.run(
            "INSERT INTO annotations(id,book_id,payload) VALUES(?,?,?)",
            [
              .text(annotation.id.uuidString), .text(annotation.bookID.uuidString),
              .blob(try LibraryJSON.encode(annotation)),
            ])
        }
        try putPreferences(snapshot.preferences)
        // 网页收藏及过滤开关与书库在同一个事务内切换，旧备份恢复为空收藏。
        for bookmark in snapshot.webBookmarks ?? [] { try putWebBookmark(bookmark) }
        try saveWebPreferencesDuringRestore(snapshot.webPreferences ?? WebPreferences())
      }
      // 旧资产仅在事务成功后逐文件回收，不递归删除整个书库目录。
      removeUnusedWebAssets(oldPaths)
    } catch {
      if restored.path.hasPrefix(paths.root.path + "/") {
        try? FileManager.default.removeItem(at: restored)
      }
      throw error
    }
  }

  // 校验关联、散列、目录树和资产清单，阻止构造备份破坏数据库关系。
  private func validateSnapshot(_ snapshot: BackupManifest) throws {
    // 提交前校验网址和唯一性，拒绝脚本地址、重复收藏及异常标题。
    let bookmarks = snapshot.webBookmarks ?? []
    guard Set(bookmarks.map(\.id)).count == bookmarks.count,
      Set(bookmarks.map(\.url)).count == bookmarks.count else { throw LibraryError.message("备份存在重复网页收藏") }
    for bookmark in bookmarks {
      guard try WebAddress.url(bookmark.url.absoluteString) == bookmark.url,
        !bookmark.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, bookmark.title.count <= 500 else {
        throw LibraryError.message("备份的网页收藏无效")
      }
    }
    // 网页书籍的来源也必须是规范化网页地址，缺少阅读副本时必须指向链接描述文件。
    for book in snapshot.books where book.format == .web {
      guard let url = book.webURL, try WebAddress.url(url.absoluteString) == url,
        book.fingerprint == Self.webFingerprint(url),
        book.hasWebReadingCopy || book.webSnapshotDate == nil else {
        throw LibraryError.message("备份的网页书籍来源无效")
      }
      if let volumes = book.webVolumes { try WebBookVolume.validateCatalog(volumes) }
      if let selected = book.webVolumeIDs {
        guard Set(selected).count == selected.count, Set(selected).isSubset(of: Set(book.webCacheVolumes.map(\.id))) else {
          throw LibraryError.message("备份的网页书籍选卷无效")
        }
      }
      if let prefixes = book.webRemovedChapterPrefixes {
        let activePrefixes = Set(book.downloadedWebChapters.map(\.resourcePrefix))
        guard prefixes.count <= 2000, Set(prefixes.values).count == prefixes.count,
          activePrefixes.isDisjoint(with: prefixes.values) else {
          throw LibraryError.message("备份的网页章节定位重复")
        }
        for (address, prefix) in prefixes {
          guard let url = URL(string: address), try WebAddress.url(address) == url,
            WebChapterAddress.identity(url) == address, Self.isWebChapterPrefix(prefix) else {
            throw LibraryError.message("备份的已删除章节定位无效")
          }
        }
      }
      if book.webChapters != nil || book.webPendingChapters != nil {
        let chapters = book.downloadedWebChapters
        guard book.hasWebReadingCopy, !chapters.isEmpty, chapters.count <= 2000,
          Set(chapters.map(\.url)).count == chapters.count,
          Set(chapters.map(\.href)).count == chapters.count,
          book.webCacheCompleted != true || book.webPendingChapters == nil else {
          throw LibraryError.message("备份的网页章节清单无效")
        }
        for chapter in chapters {
          guard try WebAddress.url(chapter.url.absoluteString) == chapter.url,
            Self.isWebChapterPrefix(chapter.resourcePrefix) else {
            throw LibraryError.message("备份的网页章节路径无效")
          }
          try chapter.navigation?.validate()
        }
      }
    }
    let bookIDs = Set(snapshot.books.map(\.id))
    let folderIDs = Set(snapshot.folders.map(\.id))
    guard bookIDs.count == snapshot.books.count, folderIDs.count == snapshot.folders.count,
      Set(snapshot.books.map(\.fingerprint)).count == snapshot.books.count,
      Set(snapshot.annotations.map(\.id)).count == snapshot.annotations.count
    else { throw LibraryError.message("备份存在重复记录") }
    for folder in snapshot.folders {
      var visited: Set<UUID> = [folder.id]
      var parent = folder.parentID
      while let id = parent {
        guard visited.insert(id).inserted,
          let ancestor = snapshot.folders.first(where: { $0.id == id })
        else { throw LibraryError.message("备份的书架层级无效") }
        parent = ancestor.parentID
      }
    }
    var required = Set(snapshot.books.flatMap(\.assetPaths))
    required.formUnion(snapshot.folders.compactMap(\.coverPath))
    if let avatar = snapshot.preferences.profileAvatarPath { required.insert(avatar) }
    guard required.isSubset(of: Set(snapshot.files.keys)),
      snapshot.books.allSatisfy({ $0.folderID == nil || folderIDs.contains($0.folderID!) }),
      snapshot.annotations.allSatisfy({ bookIDs.contains($0.bookID) })
    else { throw LibraryError.message("备份的书籍或标注关联不完整") }
    for path in snapshot.files.keys {
      try EbookArchive.validatePath(path)
      _ = try paths.url(path)
    }
  }

  // 真正的源包与仅保留的定位使用相同的资源前缀格式。
  private static func isWebChapterPrefix(_ value: String) -> Bool {
    value.isEmpty || value.range(of: "^chapters/[0-9A-Fa-f-]{36}/$", options: .regularExpression) != nil
  }

  // 恢复已经持有维护锁，直接写入设置避免触发公开写入入口的维护检查。
  private func saveWebPreferencesDuringRestore(_ value: WebPreferences) throws {
    try database.run("INSERT INTO settings(id,payload) VALUES('webPreferences',?)",
      [.blob(try LibraryJSON.encode(value))])
  }
}
