import Foundation

// 同一章的页内锚点不产生第二份缓存，书籍本身仍保留用户保存的完整来源链接。
public enum WebChapterAddress {
  public static func url(_ url: URL) throws -> URL {
    let normalized = try WebAddress.url(url.absoluteString)
    guard var parts = URLComponents(url: normalized, resolvingAgainstBaseURL: false) else { return normalized }
    parts.fragment = nil
    return parts.url ?? normalized
  }

  // 文库8的目录和正文可能经不同子域或 HTTP 跳转，按同一个章号识别缓存。
  public static func isWenku8(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "wenku8.net" || host.hasSuffix(".wenku8.net")
  }

  public static func identity(_ url: URL) -> String {
    guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
    parts.fragment = nil
    if isWenku8(url), url.path.hasPrefix("/novel/") {
      parts.scheme = "https"
      parts.host = "wenku8.net"
      parts.port = nil
    }
    return parts.string ?? url.absoluteString
  }
}

// 章节站点的导航单独保存；没有相邻链接时不会猜测数字或把返回目录当作下一章。
public struct WebChapterNavigation: Codable, Equatable, Sendable {
  public var previousURL: URL?
  public var nextURL: URL?
  public var contentsURL: URL?
  public var firstChapterURL: URL?
  // 有明确章节目录时保留站点顺序，用于发现跳章链接没有列出的插图或前置章节。
  public var chapterURLs: [URL]?
  public var volumes: [WebBookVolume]?
  public var isContents: Bool
  public init(previousURL: URL? = nil, nextURL: URL? = nil, contentsURL: URL? = nil,
    firstChapterURL: URL? = nil, isContents: Bool = false, chapterURLs: [URL]? = nil,
    volumes: [WebBookVolume]? = nil)
  {
    self.previousURL = previousURL
    self.nextURL = nextURL
    self.contentsURL = contentsURL
    self.firstChapterURL = firstChapterURL
    self.isContents = isContents
    self.chapterURLs = chapterURLs
    self.volumes = volumes
  }

  // 数据库及备份只接收有效网页地址，避免脚本地址随章节元数据传播。
  func validate() throws {
    guard (chapterURLs?.count ?? 0) <= 2001 else { throw LibraryError.message("章节目录超过支持的数量") }
    for url in [previousURL, nextURL, contentsURL, firstChapterURL].compactMap({ $0 }) + (chapterURLs ?? []) {
      guard try WebAddress.url(url.absoluteString) == url else { throw LibraryError.message("章节导航网址无效") }
    }
    if let volumes { try WebBookVolume.validateCatalog(volumes) }
  }
}

// 每章保留独立源 EPUB，合并副本使用稳定目录，追加章节不改写已有正文和 DOM 定位。
public struct WebBookChapter: Codable, Equatable, Sendable, Identifiable {
  public var id: URL { url }
  public var url: URL
  public var title: String
  public var readingPath: String
  public var resourcePrefix: String
  public var navigation: WebChapterNavigation?
  public var href: String { "OEBPS/" + resourcePrefix + "article.xhtml" }
  public init(url: URL, title: String, readingPath: String, resourcePrefix: String = "",
    navigation: WebChapterNavigation? = nil)
  {
    self.url = (try? WebChapterAddress.url(url)) ?? url
    self.title = title
    self.readingPath = readingPath
    self.resourcePrefix = resourcePrefix
    self.navigation = navigation
  }

  // Readium 的 Locator 从 EPUB 根目录定位，首章保留旧版 article.xhtml 的原始路径。
  public var startPosition: ReadingPosition {
    let locator: [String: Any] = ["href": href, "type": "application/xhtml+xml", "title": title,
      "locations": ["progression": 0]]
    // 键顺序固定，重复进入同一章时位置值可稳定比较并保存。
    let json = (try? JSONSerialization.data(withJSONObject: locator, options: [.sortedKeys, .withoutEscapingSlashes]))
      .flatMap { String(data: $0, encoding: .utf8) }
    return ReadingPosition(locatorJSON: json)
  }
}

// 方向使用稳定值，在阅读按钮和加载器之间传递，不依赖显示文案。
public enum WebChapterDirection: Equatable, Sendable { case previous, next }

extension Book {
  // 旧版单页副本按首章投影，只有识别或追加章节时才写回数据库。
  public var cachedWebChapters: [WebBookChapter] {
    guard hasWebReadingCopy, let webURL else { return [] }
    return webChapters ?? [WebBookChapter(url: webURL, title: title, readingPath: readingPath)]
  }

  // 下载进度包括已合并和已经落盘等待合并的章节。
  public var downloadedWebChapters: [WebBookChapter] { cachedWebChapters + (webPendingChapters ?? []) }

  // Locator 可能包含锚点，识别当前章时只比较资源路径，未知位置回到首章。
  public func webChapter(href: String?) -> WebBookChapter? {
    let path = href?.components(separatedBy: "#").first?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return cachedWebChapters.first(where: { $0.href == path }) ?? cachedWebChapters.first
  }
}
