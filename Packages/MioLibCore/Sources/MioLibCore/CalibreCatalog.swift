import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// 连接配置不包含持久化密码；URL 只接受 HTTP(S)，并自动补齐 Calibre 的 OPDS 入口。
public struct CalibreConnection: Sendable {
  public let catalogURL: URL
  public let username: String
  public let password: String
  public init(address: String, username: String = "", password: String = "") throws {
    var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.contains("://") { text = "http://" + text }
    guard var parts = URLComponents(string: text),
      ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
      let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil
    else { throw LibraryError.message("请输入 Calibre 服务器地址，账号和密码请填写在下方") }
    parts.fragment = nil
    if !parts.path.split(separator: "/").contains("opds") {
      parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      parts.path = "/" + (parts.path.isEmpty ? "" : parts.path + "/") + "opds"
    }
    guard let url = parts.url else { throw LibraryError.message("服务器地址无效") }
    catalogURL = url
    self.username = username
    self.password = password
  }

  // 分类、搜索和下载仅访问用户填写的服务器，不向外部链接发送登录凭据。
  public func allows(_ url: URL) -> Bool {
    func port(_ value: URL) -> Int { value.port ?? (value.scheme == "https" ? 443 : 80) }
    return url.user == nil && url.password == nil
      && url.scheme?.lowercased() == catalogURL.scheme?.lowercased()
      && url.host?.lowercased() == catalogURL.host?.lowercased() && port(url) == port(catalogURL)
  }
}

// OPDS 下载地址通常没有扩展名，因此优先用媒体类型，兼容 /get/epub/... 等路径。
public struct CalibreDownload: Identifiable, Equatable, Sendable {
  public let url: URL
  public let format: BookFormat
  public var id: String { url.absoluteString }
  public init?(url: URL, mediaType: String) {
    let type = mediaType.lowercased().split(separator: ";").first.map(String.init) ?? ""
    let types: [String: BookFormat] = [
      "application/epub+zip": .epub, "text/plain": .txt, "application/pdf": .pdf,
      "application/x-mobipocket-ebook": .mobi, "application/vnd.amazon.ebook": .azw3,
      "application/x-kf8": .azw3, "application/x-mobi8-ebook": .azw3,
    ]
    let pathFormat = url.pathComponents.dropFirst().enumerated().compactMap { index, part in
      index > 0 && url.pathComponents[index].lowercased() == "get"
        ? BookFormat(rawValue: part.lowercased()) : nil
    }.first
    guard let format = types[type] ?? BookFormat(rawValue: url.pathExtension.lowercased()) ?? pathFormat, format != .web
    else { return nil }
    self.url = url
    self.format = format
  }
}

// 导航条目与可下载书籍共用行模型；每本书默认优先导入 EPUB，再选择其他支持格式。
public struct CalibreEntry: Identifiable, Equatable, Sendable {
  public var id: String
  public var title: String
  public var authors: [String]
  public var navigationURL: URL?
  public var downloads: [CalibreDownload]
  public var preferredDownload: CalibreDownload? {
    let order: [BookFormat] = [.epub, .azw3, .mobi, .pdf, .txt]
    return order.compactMap { format in downloads.first { $0.format == format } }.first
  }
}

// 搜索模板由服务器返回，保留 library_id 等参数，以支持多个 Calibre 书库及反向代理。
public struct CalibreCatalog: Sendable {
  public var title = "Calibre 书库"
  public var entries: [CalibreEntry] = []
  public var nextURL: URL?
  public var searchTemplate: String?
  public init() {}
  public func searchURL(query: String) throws -> URL {
    guard let template = searchTemplate else { throw LibraryError.message("此目录未提供书库搜索") }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed),
      let url = URL(string: template.replacingOccurrences(of: "{searchTerms}", with: encoded)
        .replacingOccurrences(of: "{searchTerms?}", with: encoded))
    else { throw LibraryError.message("无法生成搜索地址") }
    return url
  }
}

// 只解析标准 Atom OPDS，不执行外部实体；目录限制大小，防止畸形响应耗尽内存。
public enum CalibreCatalogParser {
  public static func parse(_ data: Data, at url: URL) throws -> CalibreCatalog {
    guard data.count <= 8 * 1024 * 1024 else { throw LibraryError.message("书库目录过大") }
    let upper = String(decoding: data, as: UTF8.self).uppercased()
    guard !upper.contains("<!DOCTYPE"), !upper.contains("<!ENTITY") else {
      throw LibraryError.message("书库目录包含不受支持的 XML 声明")
    }
    let delegate = AtomCatalogDelegate(baseURL: url)
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    guard parser.parse(), delegate.isFeed else {
      throw LibraryError.message("此地址未返回 Calibre 书库目录，请检查内容服务器地址及 /opds 入口")
    }
    return delegate.catalog
  }
}

// 深度和命名空间共同区分书名、作者与导航链接，避免 XHTML 简介中的同名节点污染数据。
private final class AtomCatalogDelegate: NSObject, XMLParserDelegate {
  var catalog = CalibreCatalog()
  var isFeed = false
  private let baseURL: URL
  private var names: [String] = []
  private var bases: [URL] = []
  private var texts: [String] = []
  private var entry: CalibreEntry?
  init(baseURL: URL) { self.baseURL = baseURL }
  func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String])
  {
    let parentBase = bases.last ?? baseURL
    bases.append(attributes["xml:base"].flatMap { URL(string: $0, relativeTo: parentBase)?.absoluteURL } ?? parentBase)
    names.append(name)
    texts.append("")
    guard namespaceURI == "http://www.w3.org/2005/Atom" else { return }
    if names.count == 1 { isFeed = name == "feed" }
    if names == ["feed", "entry"] {
      entry = CalibreEntry(id: "", title: "未命名书籍", authors: [], downloads: [])
    }
    guard name == "link", let href = attributes["href"],
      names == ["feed", "link"] || names == ["feed", "entry", "link"]
    else { return }
    let marker = "MIOSEARCHTERMS"
    let safeHref = href.replacingOccurrences(of: "{searchTerms}", with: marker)
      .replacingOccurrences(of: "{searchTerms?}", with: marker)
    guard let url = URL(string: safeHref, relativeTo: bases.last)?.absoluteURL,
      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
    let relation = attributes["rel"] ?? "alternate"
    let type = attributes["type"] ?? ""
    if names.count == 2 {
      if relation == "next" { catalog.nextURL = url }
      if relation == "search", href.contains("{searchTerms") {
        catalog.searchTemplate = url.absoluteString.replacingOccurrences(of: marker, with: "{searchTerms}")
      }
    } else if relation.hasPrefix("http://opds-spec.org/acquisition"),
      let download = CalibreDownload(url: url, mediaType: type)
    {
      if entry?.downloads.contains(download) == false { entry?.downloads.append(download) }
    } else if type.lowercased().contains("application/atom+xml"),
      ["alternate", "subsection"].contains(relation)
    {
      entry?.navigationURL = url
    }
  }

  // XML 字符数据可能被多次回调，逐段拼接，结束节点时再裁去首尾空白。
  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if !texts.isEmpty { texts[texts.count - 1] += string }
  }
  func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
    let text = (texts.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if namespaceURI == "http://www.w3.org/2005/Atom" {
      switch names {
      case ["feed", "title"]: if !text.isEmpty { catalog.title = text }
      case ["feed", "entry", "id"]: entry?.id = text
      case ["feed", "entry", "title"]: if !text.isEmpty { entry?.title = text }
      case ["feed", "entry", "author", "name"]: if !text.isEmpty { entry?.authors.append(text) }
      case ["feed", "entry"]:
        if var value = entry, value.navigationURL != nil || !value.downloads.isEmpty {
          if value.id.isEmpty { value.id = value.navigationURL?.absoluteString ?? value.downloads[0].id }
          catalog.entries.append(value)
        }
        entry = nil
      default: break
      }
    }
    names.removeLast()
    bases.removeLast()
    texts.removeLast()
  }
}
