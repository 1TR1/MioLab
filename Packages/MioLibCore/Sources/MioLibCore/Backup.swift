import Foundation
import MioZIPFoundation

// 备份保存逻辑快照而非直接复制 WAL 数据库，版本与文件指纹均可验证。
struct BackupManifest: Codable {
  var version: Int = 1
  var books: [Book]
  var folders: [LibraryFolder]
  var annotations: [Annotation]
  var preferences: ReaderPreferences
  var files: [String: String]
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
    var references = Set(
      books.flatMap {
        [$0.originalPath, $0.readingPath] + [$0.coverPath, $0.customCoverPath].compactMap { $0 }
      })
    references.formUnion(folders.compactMap(\.coverPath))
    if let avatar = preferences.profileAvatarPath { references.insert(avatar) }
    var hashes: [String: String] = [:]
    for relative in references {
      hashes[relative] = try FileFingerprint.hash(file: paths.url(relative))
    }
    let snapshot = BackupManifest(
      books: books, folders: folders, annotations: annotations, preferences: preferences,
      files: hashes)
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
      guard snapshot.version == 1 else { throw LibraryError.message("此备份版本暂不支持，请更新 MioLib") }
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
        oldBooks.flatMap {
          [$0.originalPath, $0.readingPath] + [$0.coverPath, $0.customCoverPath].compactMap { $0 }
        } + oldFolders.compactMap(\.coverPath))
      if let avatar = try preferences().profileAvatarPath { oldPaths.insert(avatar) }
      for index in snapshot.books.indices {
        snapshot.books[index].originalPath = prefix + "/" + snapshot.books[index].originalPath
        snapshot.books[index].readingPath = prefix + "/" + snapshot.books[index].readingPath
        snapshot.books[index].coverPath = snapshot.books[index].coverPath.map { prefix + "/" + $0 }
        snapshot.books[index].customCoverPath = snapshot.books[index].customCoverPath.map {
          prefix + "/" + $0
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
        for table in ["annotations", "books", "folders", "jobs", "settings"] {
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
      }
      // 旧资产仅在事务成功后逐文件回收，不递归删除整个书库目录。
      for relative in oldPaths {
        if let url = try? paths.url(relative) { try? FileManager.default.removeItem(at: url) }
      }
    } catch {
      if restored.path.hasPrefix(paths.root.path + "/") {
        try? FileManager.default.removeItem(at: restored)
      }
      throw error
    }
  }

  // 校验关联、散列、目录树和资产清单，阻止构造备份破坏数据库关系。
  private func validateSnapshot(_ snapshot: BackupManifest) throws {
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
    var required = Set(
      snapshot.books.flatMap {
        [$0.originalPath, $0.readingPath] + [$0.coverPath, $0.customCoverPath].compactMap { $0 }
      })
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
}
