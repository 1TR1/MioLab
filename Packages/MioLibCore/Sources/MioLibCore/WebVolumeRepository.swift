import Foundation

extension LibraryRepository {
  // 打开书籍的面板只在确认后写入本次选择。更换下载卷时保留已保存的正文与进度。
  public func chooseWebCacheVolumes(_ selection: Set<String>, for original: Book,
    catalog: [WebBookVolume]? = nil) throws -> Book
  {
    try writable()
    let snapshot = try currentWebBook(matching: original)
    var latest = snapshot
    if latest.webVolumes == nil, let catalog {
      try WebBookVolume.validateCatalog(catalog)
      latest.webVolumes = catalog
    }

    // 按目录顺序提交选中的卷。空选择由面板的跳过按钮处理。
    let available = latest.webCacheVolumes.map(\.id)
    guard !selection.isEmpty, selection.isSubset(of: Set(available)) else {
      throw LibraryError.message("请选择当前目录中的卷")
    }
    let requested = available.filter(selection.contains)
    if latest.webVolumeIDs != requested || latest.webVolumes != snapshot.webVolumes {
      latest.webVolumeIDs = requested
      latest.webCacheRevision = UUID()
      latest.webCacheCompleted = nil
      try putBook(latest)
    }
    return latest
  }

  // 旧书首次取得目录时只补充卷信息，已经下载的章、位置和模式开关原样保留。
  @discardableResult public func recordWebVolumes(_ volumes: [WebBookVolume], for original: Book) throws -> Book {
    try writable()
    var current = try currentWebBook(matching: original)
    guard current.webVolumes == nil else { return current }
    try WebBookVolume.validateCatalog(volumes)
    current.webVolumes = volumes
    if current.webVolumeIDs == [WebBookVolume.wholeBook.id], volumes != [.wholeBook] {
      current.webVolumeIDs = nil
    }
    try putBook(current)
    return current
  }

  // 选中一卷后允许队列下载。删除会同步取消该卷的选择，重开书时不会重新下载。
  @discardableResult public func setWebVolumeCached(_ enabled: Bool, volumeID: String,
    for original: Book) async throws -> Book
  {
    try writable()
    let snapshot = try currentWebBook(matching: original)
    let volumes = snapshot.webCacheVolumes
    guard let volume = volumes.first(where: { $0.id == volumeID }) else {
      throw LibraryError.message("此卷已改变，请重新选择")
    }
    var selection = Set(volumes.filter(snapshot.wantsWebVolume).map(\.id))
    if enabled {
      guard selection.insert(volumeID).inserted else { return snapshot }
      var latest = snapshot
      latest.webVolumeIDs = volumes.map(\.id).filter(selection.contains)
      latest.webCacheRevision = UUID()
      latest.webCacheCompleted = nil
      try putBook(latest)
      return latest
    }
    selection.remove(volumeID)
    let removed = snapshot.downloadedWebChapters(in: volume)
    if removed.isEmpty, !snapshot.wantsWebVolume(volume) { return snapshot }
    return try await removeWebVolume(removed, selecting: volumes.map(\.id).filter(selection.contains), from: snapshot)
  }

  // 先准备剩余卷的阅读包，再一起提交选择和章节清单，旧包的清理发生在提交之后。
  private func removeWebVolume(_ removed: [WebBookChapter], selecting selection: [String],
    from snapshot: Book) async throws -> Book
  {
    let removedHrefs = Set(removed.map(\.href))
    let keepPublished = snapshot.cachedWebChapters.filter { !removedHrefs.contains($0.href) }
    let keepPending = (snapshot.webPendingChapters ?? []).filter { !removedHrefs.contains($0.href) }
    // 没有保留下来的已发布章时，先发布其余卷已经落盘的章，避免失去阅读入口。
    let readable = keepPublished.isEmpty ? keepPending : keepPublished
    let pending = keepPublished.isEmpty ? [] : keepPending
    let rebuilding = !readable.isEmpty && readable != snapshot.cachedWebChapters
    let newPath = rebuilding ? "Reading/\(UUID().uuidString).epub" : snapshot.readingPath
    let newFile = try paths.url(newPath)
    do {
      if rebuilding {
        try await WebBookAssembler.combine(readable, paths: paths, title: snapshot.title, destination: newFile)
      }
      try Task.checkCancellation()
      try writable()
      var latest = try currentWebBook(matching: snapshot)
      guard latest.readingPath == snapshot.readingPath, latest.downloadedWebChapters == snapshot.downloadedWebChapters,
        latest.webVolumes == snapshot.webVolumes else {
        throw LibraryError.message("缓存内容刚刚更新，请重试删除")
      }

      // 记录被移除章的资源前缀，以便重新缓存后恢复已有笔记、书签及高亮。
      for chapter in removed {
        if latest.webRemovedChapterPrefixes == nil { latest.webRemovedChapterPrefixes = [:] }
        latest.webRemovedChapterPrefixes?[WebChapterAddress.identity(chapter.url)] = chapter.resourcePrefix
      }
      latest.webCacheRevision = UUID()
      latest.webVolumeIDs = selection
      latest.webChapters = readable.isEmpty ? nil : readable
      latest.webPendingChapters = pending.isEmpty ? nil : pending
      latest.readingPath = readable.isEmpty ? latest.originalPath : newPath
      latest.webSnapshotDate = readable.isEmpty ? nil : latest.webSnapshotDate
      latest.webCacheCompleted = !readable.isEmpty && !selection.isEmpty && snapshot.webCacheCompleted == true ? true : nil
      if readable.isEmpty || latest.position?.webResourceHref.map(removedHrefs.contains) == true {
        latest.position = readable.first?.startPosition
        latest.progress = 0
      }
      try putBook(latest)
      removeUnusedWebAssets(Set(removed.map(\.readingPath) + [snapshot.readingPath]))
      return latest
    } catch {
      if rebuilding { try? FileManager.default.removeItem(at: newFile) }
      throw error
    }
  }
}
