import Foundation

// 卷名用于显示，首章的规范身份用于识别同一卷。没有卷目录的网站按整本管理。
public struct WebBookVolume: Codable, Equatable, Sendable, Identifiable {
  public let title: String
  public let chapterURLs: [URL]
  public var id: String { chapterURLs.first.map(WebChapterAddress.identity) ?? "whole-book" }
  public static let wholeBook = Self(title: "全书", chapterURLs: [])

  public init(title: String, chapterURLs: [URL]) {
    self.title = title
    self.chapterURLs = chapterURLs
  }

  // 持久化目录前核对数量、地址和卷之间的归属，避免一章同时进入两卷。
  public static func validateCatalog(_ volumes: [Self]) throws {
    guard !volumes.isEmpty, volumes.count <= 2000 else {
      throw LibraryError.message("卷目录为空或超出支持的数量")
    }
    let urls = volumes.flatMap(\.chapterURLs)
    guard urls.count <= 2000, Set(urls.map(WebChapterAddress.identity)).count == urls.count else {
      throw LibraryError.message("卷目录包含重复章节或超过 2,000 章")
    }
    for volume in volumes {
      guard !volume.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, volume.title.count <= 500,
        !volume.chapterURLs.isEmpty || volumes == [.wholeBook] else {
        throw LibraryError.message("卷目录无效")
      }
    }
    for url in urls {
      guard try WebChapterAddress.url(url) == url else { throw LibraryError.message("卷目录包含无效网址") }
    }
  }
}

extension Book {
  // 历史版本下载过但当前目录未收录的章节仍可离线阅读和清理。
  public var webCacheVolumes: [WebBookVolume] {
    guard let webVolumes, webVolumes != [.wholeBook] else { return [.wholeBook] }
    let listed = Set(webVolumes.flatMap(\.chapterURLs).map(WebChapterAddress.identity))
    let other = downloadedWebChapters.map(\.url).filter { !listed.contains(WebChapterAddress.identity($0)) }
    if other.isEmpty { return webVolumes }
    return webVolumes + [.init(title: "目录外章节", chapterURLs: other)]
  }

  public var hasWebCacheSelection: Bool { webVolumeIDs?.isEmpty != true }

  // 已保存的正文、确认过的卷选择和之后的缓存改动都算该来源的缓存记录。
  // 新书的空选择和只读取卷目录不会产生记录。
  public var hasWebCacheRecord: Bool {
    guard format == .web else { return false }
    return hasWebReadingCopy || webPendingChapters?.isEmpty == false
      || webVolumeIDs?.isEmpty == false || webCacheRevision != nil
  }

  public func wantsWebVolume(_ volume: WebBookVolume) -> Bool {
    webVolumeIDs?.contains(volume.id) ?? true
  }

  // 缓存任务与手动切章共用选择约束，未选卷不会因重新打开书而被下载。
  public func allowsWebCaching(at url: URL) -> Bool {
    guard let webVolumeIDs else { return true }
    guard let webVolumes, webVolumes != [.wholeBook] else {
      return webVolumeIDs.contains(WebBookVolume.wholeBook.id)
    }
    let key = WebChapterAddress.identity(url)
    // 目录外的历史章节已在本地。新的网络下载只允许进入明确选中的卷。
    return webVolumes.contains { volume in
      webVolumeIDs.contains(volume.id) && volume.chapterURLs.contains { WebChapterAddress.identity($0) == key }
    }
  }

  // 本章可能只完成落盘，还未进入阅读副本；设置中的删除需要覆盖两种状态。
  public func downloadedWebChapters(in volume: WebBookVolume) -> [WebBookChapter] {
    guard volume != .wholeBook else { return downloadedWebChapters }
    let keys = Set(volume.chapterURLs.map(WebChapterAddress.identity))
    return downloadedWebChapters.filter { keys.contains(WebChapterAddress.identity($0.url)) }
  }

  // 为重新下载的章恢复原资源前缀，保留笔记定位；首章的空前缀只能分配一次。
  func webResourcePrefix(for url: URL, isFirst: Bool) -> String {
    if let prior = webRemovedChapterPrefixes?[WebChapterAddress.identity(url)] { return prior }
    if isFirst, webRemovedChapterPrefixes?.values.contains("") != true { return "" }
    return "chapters/\(UUID().uuidString)/"
  }

  mutating func restoreWebChapterPrefix(for url: URL) {
    webRemovedChapterPrefixes?.removeValue(forKey: WebChapterAddress.identity(url))
    if webRemovedChapterPrefixes?.isEmpty == true { webRemovedChapterPrefixes = nil }
  }
}

extension ReadingPosition {
  // 删除卷时只根据实际资源判断保存位置是否还在阅读副本中。
  var webResourceHref: String? {
    guard let locatorJSON, let data = locatorJSON.data(using: .utf8),
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let href = json["href"] as? String else { return nil }
    return href.components(separatedBy: "#").first?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }
}
