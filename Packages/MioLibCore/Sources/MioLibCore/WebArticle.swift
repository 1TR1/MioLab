import Foundation
import MioZIPFoundation

// 浏览器只传递有类型的正文块，原网站脚本、样式和任意 HTML 不会进入本地阅读副本。
public struct WebArticle: Codable, Equatable, Sendable {
  public var title: String
  public var byline: String
  public var language: String
  public var blocks: [WebArticleBlock]
  // 导航来自原网页而非 Readability 清理后的正文，避免下一章链接被正文过滤移除。
  public var pageURL: URL?
  public var navigation: WebChapterNavigation?
  public init(title: String, byline: String = "", language: String = "zh", blocks: [WebArticleBlock]) {
    self.title = title
    self.byline = byline
    self.language = language
    self.blocks = blocks
  }
}

// 标题、段落、引文、列表、代码、图片及同页注释保留阅读语义。
public struct WebArticleBlock: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case heading, paragraph, quote, listItem, code, image, footnote }
  public var kind: Kind
  public var text: String
  public var level: Int?
  public var url: URL?
  // 引用只传正文片段的 UTF-16 范围和本章注释编号，不携带源标签或站点地址。
  public var noteReferences: [WebArticleNoteReference]?
  public var noteID: Int?
  public init(_ kind: Kind, text: String, level: Int? = nil, url: URL? = nil) {
    self.kind = kind
    self.text = text
    self.level = level
    self.url = url
  }
}

// JavaScript 字符串以 UTF-16 计数；转换器验证区间后再插入本地链接。
public struct WebArticleNoteReference: Codable, Equatable, Sendable {
  public var offset: Int
  public var length: Int
  public var noteID: Int

  public init(offset: Int, length: Int, noteID: Int) {
    self.offset = offset
    self.length = length
    self.noteID = noteID
  }
}

// 图片资源与来源 URL 一起提交，EPUB 只引用校验后的本地栅格资源。
public struct WebArticleImage: Sendable {
  public let url: URL
  public let data: Data
  public let mediaType: String
  public init(url: URL, data: Data, mediaType: String = "image/jpeg") {
    self.url = url
    self.data = data
    self.mediaType = mediaType
  }
}

// 正文生成标准 EPUB 3，直接复用 Readium 的水平分页、主题、搜索、续读与高亮功能。
public enum WebArticleConverter {
  public static func convert(_ article: WebArticle, images: [WebArticleImage] = [], source: URL,
    title: String, destination: URL) async throws
  {
    let source = try WebAddress.url(source.absoluteString)
    guard !article.blocks.isEmpty, article.blocks.count <= 20_000,
      article.blocks.reduce(0, { $0 + $1.text.utf8.count }) <= 8 * 1024 * 1024,
      article.title.count <= 2000, article.byline.count <= 2000, images.count <= 20,
      images.reduce(0, { $0 + $1.data.count }) <= 24 * 1024 * 1024,
      article.blocks.contains(where: { ($0.kind != .image && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        || ($0.kind == .image && $0.url != nil) }) else {
      throw LibraryError.message("没有可阅读的正文，或正文过大；请使用原网页阅读")
    }
    let language = article.language.range(of: "^[a-zA-Z]{2,8}(-[a-zA-Z0-9]{1,8})*$", options: .regularExpression) != nil
      ? article.language : "zh"
    let displayTitle = article.title.isEmpty ? title : article.title
    var resources: [URL: (path: String, type: String, data: Data)] = [:]
    // 资源名由本地序号生成，拒绝脚本图片、路径注入及伪造的媒体类型。
    for image in images {
      let url = try WebAddress.url(image.url.absoluteString)
      guard image.data.count <= 6 * 1024 * 1024 else { throw LibraryError.message("正文图片过大") }
      let suffix: String
      if image.mediaType == "image/jpeg", image.data.starts(with: [0xff, 0xd8, 0xff]) { suffix = "jpg" }
      else if image.mediaType == "image/png", image.data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { suffix = "png" }
      else { throw LibraryError.message("正文图片格式无效") }
      if resources[url] == nil {
        resources[url] = ("images/image\(resources.count).\(suffix)", image.mediaType, image.data)
      }
    }
    var body = "<h1>\(xml(displayTitle))</h1>"
    if !article.byline.isEmpty { body += "<p class=\"byline\">\(xml(article.byline))</p>" }
    body += "<p class=\"source\"><a href=\"\(xml(source.absoluteString))\">\(xml(source.host ?? "原网页"))</a></p>"
    var navigation = "<li><a href=\"article.xhtml\">\(xml(displayTitle))</a></li>"
    // 编号由提取脚本在本章内生成。只有确实写入包的目标才允许成为注释链接。
    let noteIDs = Set(article.blocks.filter { $0.kind == .footnote }.compactMap(\.noteID).filter { $0 >= 0 })
    var unwrittenNotes = noteIDs
    // 所有正文均作为 XML 文本转义，不接受网页传来的标签、事件属性或远程资源引用。
    for (index, block) in article.blocks.enumerated() {
      try Task.checkCancellation()
      switch block.kind {
      case .heading:
        let level = min(6, max(2, block.level ?? 2))
        body += "<h\(level) id=\"section\(index)\">\(inlineText(block, noteIDs: noteIDs))</h\(level)>"
        navigation += "<li><a href=\"article.xhtml#section\(index)\">\(xml(block.text))</a></li>"
      case .paragraph: body += "<p>\(inlineText(block, noteIDs: noteIDs, lineBreaks: true))</p>"
      case .quote: body += "<blockquote><p>\(inlineText(block, noteIDs: noteIDs))</p></blockquote>"
      case .listItem: body += "<p class=\"list-item\">\(inlineText(block, noteIDs: noteIDs))</p>"
      case .code: body += "<pre><code>\(xml(block.text))</code></pre>"
      case .footnote:
        let content = xml(block.text).replacingOccurrences(of: "\n", with: "<br/>")
        if let id = block.noteID, unwrittenNotes.remove(id) != nil {
          body += "<aside id=\"miolib-note-\(id)\" epub:type=\"footnote\" role=\"doc-footnote\"><p>\(content)</p></aside>"
        } else { body += "<p>\(content)</p>" }
      case .image:
        let text = xml(block.text)
        if let url = block.url.flatMap({ try? WebAddress.url($0.absoluteString) }), let resource = resources[url] {
          body += "<figure><img src=\"\(resource.path)\" alt=\"\(text)\"/>"
          if !block.text.isEmpty { body += "<figcaption>\(text)</figcaption>" }
          body += "</figure>"
        } else { body += "<figure><figcaption>\(text.isEmpty ? "图片暂不可用，可在原网页查看" : text)</figcaption></figure>" }
      }
    }
    let archive = try await Archive(url: destination, accessMode: .create)
    try await EbookArchive.add(archive, path: "mimetype", data: Data("application/epub+zip".utf8), stored: true)
    try await EbookArchive.add(archive, path: "META-INF/container.xml", data: Data("""
      <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
      """.utf8))
    // 样式只控制正文语义和图片适配，实际字号、页边距和配色继续由阅读偏好管理。
    let html = """
      <?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(language)"><head><title>\(xml(displayTitle))</title><style>
      body{line-height:1.6}img{max-width:100%;max-height:70vh;object-fit:contain}figure{margin:1em 0;break-inside:avoid}figcaption,.byline,.source{font-size:.85em}pre{white-space:pre-wrap;overflow-wrap:anywhere}h1,h2,h3,h4,h5,h6{break-after:avoid}.list-item,.byline,.source{text-indent:0!important}blockquote{margin-inline:1em}
      </style></head><body data-miolib-web-article="true">\(body)</body></html>
      """
    try await EbookArchive.add(archive, path: "OEBPS/article.xhtml", data: Data(html.utf8))
    var manifest = ""
    // 图片顺序稳定，便于备份校验和排查站点资源缺失。
    for (index, resource) in resources.values.sorted(by: { $0.path < $1.path }).enumerated() {
      manifest += "<item id=\"image\(index)\" href=\"\(resource.path)\" media-type=\"\(resource.type)\"/>"
      try await EbookArchive.add(archive, path: "OEBPS/" + resource.path, data: resource.data)
    }
    let modified = ISO8601DateFormatter().string(from: Date())
    let opf = """
      <?xml version="1.0" encoding="UTF-8"?><package version="3.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="bookid">urn:sha256:\(FileFingerprint.hash(Data(body.utf8)))</dc:identifier><dc:title>\(xml(title))</dc:title><dc:creator>\(xml(article.byline))</dc:creator><dc:language>\(language)</dc:language><dc:source>\(xml(source.absoluteString))</dc:source><meta property="dcterms:modified">\(modified)</meta></metadata><manifest><item id="article" href="article.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>\(manifest)</manifest><spine><itemref idref="article"/></spine></package>
      """
    try await EbookArchive.add(archive, path: "OEBPS/content.opf", data: Data(opf.utf8))
    let nav = """
      <?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><nav epub:type="toc"><ol>\(navigation)</ol></nav></body></html>
      """
    try await EbookArchive.add(archive, path: "OEBPS/nav.xhtml", data: Data(nav.utf8))
  }

  // 先按原始范围切片，再逐段转义。无效、重叠或没有目标的引用保留为普通文字。
  private static func inlineText(_ block: WebArticleBlock, noteIDs: Set<Int>, lineBreaks: Bool = false) -> String {
    let source = block.text
    func escaped(_ text: Substring) -> String {
      let value = xml(String(text))
      return lineBreaks ? value.replacingOccurrences(of: "\n", with: "<br/>") : value
    }

    guard let references = block.noteReferences, !references.isEmpty else { return escaped(source[...]) }
    let length = source.utf16.count
    var start = source.startIndex
    var markup = ""
    for reference in references {
      guard noteIDs.contains(reference.noteID), (0...length).contains(reference.offset),
        reference.length > 0, reference.length <= length - reference.offset,
        let range = Range(NSRange(location: reference.offset, length: reference.length), in: source),
        range.lowerBound >= start else { continue }
      markup += escaped(source[start..<range.lowerBound])
      markup += "<a href=\"#miolib-note-\(reference.noteID)\" epub:type=\"noteref\" role=\"doc-noteref\">\(escaped(source[range]))</a>"
      start = range.upperBound
    }
    return markup + escaped(source[start...])
  }

  // 清理 XML 1.0 不允许的控制字符后再转义，防止合法网页文字生成损坏的 EPUB。
  static func xml(_ text: String) -> String {
    let scalars = text.unicodeScalars.filter {
      $0.value == 9 || $0.value == 10 || $0.value == 13 || (0x20...0xd7ff).contains($0.value)
        || (0xe000...0xfffd).contains($0.value) || (0x10000...0x10ffff).contains($0.value)
    }
    return TextBookConverter.escape(String(String.UnicodeScalarView(scalars)))
  }
}
