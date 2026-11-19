import Foundation

// 网址统一校验和规范化，保留章节路径、查询和锚点，不接收脚本、本地文件或嵌入密码。
public enum WebAddress {
  public static func url(_ input: String) throws -> URL {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.count <= 8192,
      text.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
      throw LibraryError.message("请输入有效的网址，例如 https://example.com")
    }
    let hasScheme = text.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil
    let hostWithPort = text.range(of: "^[^/:?#]+:[0-9]+([/?#]|$)", options: .regularExpression) != nil
    let address = text.hasPrefix("//") ? "https:" + text : hasScheme && !hostWithPort ? text : "https://" + text
    guard var parts = URLComponents(string: address),
      let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
      let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
      parts.port == nil || (1...65535).contains(parts.port!) else {
      throw LibraryError.message("仅支持不含账号密码的 HTTP 或 HTTPS 网址")
    }
    parts.scheme = scheme
    parts.host = host.lowercased()
    if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
    if parts.path.isEmpty { parts.path = "/" }
    guard let result = parts.url else { throw LibraryError.message("网址格式无效") }
    return result
  }
}

// 网页收藏独立于电子书文件，稳定 ID 支持编辑、访问记录与完整备份。
public struct WebBookmark: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var title: String
  public var url: URL
  public var createdAt: Date
  public var lastOpenedAt: Date?
  public init(id: UUID = UUID(), title: String, url: URL, createdAt: Date = Date(), lastOpenedAt: Date? = nil) {
    self.id = id
    self.title = title
    self.url = url
    self.createdAt = createdAt
    self.lastOpenedAt = lastOpenedAt
  }
}

// 默认开启广告过滤；设置独立存储，避免与阅读字号防抖写入互相覆盖。
public struct WebPreferences: Codable, Equatable, Sendable {
  public var blocksAds = true
  public init(blocksAds: Bool = true) { self.blocksAds = blocksAds }
}

extension LibraryRepository {
  // 收藏按最近访问排列，未访问的收藏按添加时间排列，再用 ID 保持稳定顺序。
  public func webBookmarks() throws -> [WebBookmark] {
    try database.data("SELECT payload FROM web_bookmarks").map {
      try LibraryJSON.decode(WebBookmark.self, from: $0)
    }.sorted {
      let left = $0.lastOpenedAt ?? $0.createdAt
      let right = $1.lastOpenedAt ?? $1.createdAt
      return left == right ? $0.id.uuidString < $1.id.uuidString : left > right
    }
  }

  // 同一规范化网址重复收藏时更新标题，保留原 ID、添加时间和访问记录。
  @discardableResult public func saveWebBookmark(address: String, title: String, id: UUID? = nil) throws -> WebBookmark {
    try writable()
    let url = try WebAddress.url(address)
    let bookmarks = try webBookmarks()
    let duplicate = bookmarks.first { $0.url == url }
    if let id, duplicate != nil && duplicate?.id != id { throw LibraryError.message("此网址已在收藏中") }
    var bookmark = id.flatMap { wanted in bookmarks.first { $0.id == wanted } }
      ?? duplicate ?? WebBookmark(title: "", url: url)
    if let id, !bookmarks.contains(where: { $0.id == id }) { throw LibraryError.message("此收藏已被删除") }
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard name.count <= 500 else { throw LibraryError.message("收藏标题最多 500 字") }
    bookmark.title = name.isEmpty ? url.host ?? "网页" : name
    bookmark.url = url
    try putWebBookmark(bookmark)
    return bookmark
  }

  // 页面加载成功后才记录访问，不将输入错误或网络失败记为已读。
  public func markWebBookmarkOpened(_ url: URL) throws {
    try writable()
    let normalized = try WebAddress.url(url.absoluteString)
    guard var bookmark = try webBookmarks().first(where: { $0.url == normalized }) else { return }
    bookmark.lastOpenedAt = Date()
    try putWebBookmark(bookmark)
  }

  // 删除只移除用户选中的收藏，不影响电子书或网站的登录数据。
  public func deleteWebBookmark(_ id: UUID) throws {
    try writable()
    try database.run("DELETE FROM web_bookmarks WHERE id=?", [.text(id.uuidString)])
  }

  // 数据库用网址唯一约束保护不同入口并发保存的结果。
  func putWebBookmark(_ bookmark: WebBookmark) throws {
    try database.run(
      "INSERT INTO web_bookmarks(id,url,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET url=excluded.url,payload=excluded.payload",
      [.text(bookmark.id.uuidString), .text(bookmark.url.absoluteString), .blob(try LibraryJSON.encode(bookmark))])
  }

  // 与电子书偏好共用 settings 表，但使用不同主键。
  public func webPreferences() throws -> WebPreferences {
    guard let data = try database.data("SELECT payload FROM settings WHERE id='webPreferences'").first else { return WebPreferences() }
    return try LibraryJSON.decode(WebPreferences.self, from: data)
  }
  public func saveWebPreferences(_ value: WebPreferences) throws {
    try writable()
    try database.run("INSERT INTO settings(id,payload) VALUES('webPreferences',?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
      [.blob(try LibraryJSON.encode(value))])
  }
}
