import Foundation
import MioZIPFoundation

// 合并缓存章节时原样复制正文与图片，旧章节的资源路径和 DOM 选择定位继续保持稳定。
enum WebBookAssembler {
  static func combine(_ chapters: [WebBookChapter], paths: LibraryPaths, title: String,
    destination: URL) async throws
  {
    guard !chapters.isEmpty, chapters.count <= 2000 else { throw LibraryError.message("缓存章节数量超出限制") }
    let archive = try await Archive(url: destination, accessMode: .create)
    try await EbookArchive.add(archive, path: "mimetype", data: Data("application/epub+zip".utf8), stored: true)
    try await EbookArchive.add(archive, path: "META-INF/container.xml", data: Data("""
      <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
      """.utf8))
    var manifest = ""
    var spine = ""
    var navigation = ""
    var copied: Set<String> = []
    var total: UInt64 = 0
    // 每章从自己的源 EPUB 拷贝到固定前缀下，图片的相对路径仍与原正文相同。
    for chapter in chapters {
      try Task.checkCancellation()
      let chapterID = chapter.resourcePrefix.isEmpty ? "article"
        : "chapter" + String(FileFingerprint.hash(Data(chapter.resourcePrefix.utf8)).prefix(16))
      let source = try await Archive(url: paths.url(chapter.readingPath), accessMode: .read)
      var hasArticle = false
      for entry in try await source.entries() where entry.path.hasPrefix("OEBPS/") {
        if ["OEBPS/content.opf", "OEBPS/nav.xhtml"].contains(entry.path) { continue }
        let local = String(entry.path.dropFirst("OEBPS/".count))
        let relative = chapter.resourcePrefix + local
        try EbookArchive.validatePath(relative)
        guard entry.type == .file, copied.insert(relative).inserted else { throw LibraryError.message("章节资源重复或无效") }
        total += entry.uncompressedSize
        guard total <= 512 * 1024 * 1024 else { throw LibraryError.message("缓存正文超过 512 MB，请另存为新书") }
        let data = try await EbookArchive.read(source, path: entry.path, limit: 64 * 1024 * 1024)
        try await EbookArchive.add(archive, path: "OEBPS/" + relative, data: data)
        let type: String
        switch URL(fileURLWithPath: local).pathExtension.lowercased() {
        case "xhtml": type = "application/xhtml+xml"
        case "jpg", "jpeg": type = "image/jpeg"
        case "png": type = "image/png"
        default: throw LibraryError.message("章节包含未知资源类型")
        }
        let identifier = local == "article.xhtml" ? chapterID : "resource\(copied.count)"
        manifest += "<item id=\"\(identifier)\" href=\"\(TextBookConverter.escape(relative))\" media-type=\"\(type)\"/>"
        if local == "article.xhtml" { hasArticle = true }
      }
      guard hasArticle else { throw LibraryError.message("章节正文文件缺失") }
      spine += "<itemref idref=\"\(chapterID)\"/>"
      // 保留原章节内部标题目录，前缀只在目录链接上添加，不改变正文节点。
      let navData = try await EbookArchive.read(source, path: "OEBPS/nav.xhtml", limit: 64 * 1024 * 1024)
      let navText = String(decoding: navData, as: UTF8.self)
      if let start = navText.range(of: "<ol>"), let end = navText.range(of: "</ol>", options: .backwards), start.upperBound <= end.lowerBound {
        let items = String(navText[start.upperBound..<end.lowerBound])
          .replacingOccurrences(of: "href=\"article.xhtml", with: "href=\"\(chapter.resourcePrefix)article.xhtml")
        navigation += items
      } else {
        navigation += "<li><a href=\"\(chapter.resourcePrefix)article.xhtml\">\(WebArticleConverter.xml(chapter.title))</a></li>"
      }
    }
    // 聚合包仅新增清单与书脊；原网站脚本和导航 HTML 不进入阅读器。
    let modified = ISO8601DateFormatter().string(from: Date())
    let opf = """
      <?xml version="1.0"?><package version="3.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="bookid">urn:uuid:\(UUID().uuidString)</dc:identifier><dc:title>\(WebArticleConverter.xml(title))</dc:title><dc:language>zh</dc:language><meta property="dcterms:modified">\(modified)</meta></metadata><manifest>\(manifest)<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine>\(spine)</spine></package>
      """
    try await EbookArchive.add(archive, path: "OEBPS/content.opf", data: Data(opf.utf8))
    let nav = """
      <?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><nav epub:type="toc"><ol>\(navigation)</ol></nav></body></html>
      """
    try await EbookArchive.add(archive, path: "OEBPS/nav.xhtml", data: Data(nav.utf8))
  }
}
