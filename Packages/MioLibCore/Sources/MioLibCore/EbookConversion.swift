import CLibMobi
import Foundation
import MioZIPFoundation

#if canImport(FoundationXML)
  import FoundationXML
#endif

// XML 只读取元数据，不解析外部实体；命名空间前缀不影响 EPUB 2 / 3。
final class EPUBMetadataParser: NSObject, XMLParserDelegate {
  var rootfile = "", title = "", author = "", coverID = "", coverHref = ""
  var items: [String: String] = [:]
  private var current = ""
  private var text = ""
  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes attributesDict: [String: String]
  ) {
    current = elementName.components(separatedBy: ":").last ?? elementName
    text = ""
    if current == "rootfile", rootfile.isEmpty { rootfile = attributesDict["full-path"] ?? "" }
    if current == "meta", attributesDict["name"] == "cover" {
      coverID = attributesDict["content"] ?? ""
    }
    if current == "item", let id = attributesDict["id"], let href = attributesDict["href"] {
      items[id] = href
      if attributesDict["properties"]?.split(separator: " ").contains("cover-image") == true {
        coverHref = href
      }
    }
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let name = elementName.components(separatedBy: ":").last ?? elementName
    if name == "title", title.isEmpty {
      title = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if name == "creator", author.isEmpty {
      author = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }
  static func read(_ data: Data) throws -> EPUBMetadataParser {
    let delegate = EPUBMetadataParser()
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    guard parser.parse() else { throw LibraryError.message("电子书目录或元数据已损坏") }
    if delegate.coverHref.isEmpty { delegate.coverHref = delegate.items[delegate.coverID] ?? "" }
    return delegate
  }
}

// ZIP 操作集中检查路径、条目类型与大小，供阅读副本和备份共同使用。
public enum EbookArchive {
  // ZIP 消费闭包可跨执行器调用，缓冲区用锁保护以满足并发约束。
  private final class Buffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data, limit: UInt64) throws {
      lock.lock()
      defer { lock.unlock() }
      guard UInt64(data.count + chunk.count) <= limit else { throw LibraryError.message("电子书内容过大") }
      data.append(chunk)
    }
    func value() -> Data {
      lock.lock()
      defer { lock.unlock() }
      return data
    }
  }
  public static func validatePath(_ path: String) throws {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
      !path.split(separator: "/").contains(".."), !path.contains(":")
    else {
      throw LibraryError.message("压缩包包含无效路径")
    }
  }
  static func read(_ archive: Archive, path: String, limit: UInt64 = 16 * 1024 * 1024) async throws
    -> Data
  {
    try validatePath(path)
    guard let entry = try await archive.get(path), entry.type == .file,
      entry.uncompressedSize <= limit
    else {
      throw LibraryError.message("电子书缺少必要文件，或内容大小异常：\(path)")
    }
    let output = Buffer()
    let checksum = try await archive.extract(entry) { data in
      try Task.checkCancellation()
      try output.append(data, limit: limit)
    }
    guard checksum==entry.checksum else{throw LibraryError.message("电子书内容校验失败：\(path)")}
    return output.value()
  }
  static func add(_ archive: Archive, path: String, data: Data, stored: Bool = false) async throws {
    try validatePath(path)
    try await archive.addEntry(
      with: path, type: .file, uncompressedSize: Int64(data.count),
      compressionMethod: stored ? .none : .deflate
    ) { position, count in
      try Task.checkCancellation()
      let start = Int(position)
      return data.subdata(in: start..<min(data.count, start + count))
    }
  }
  public static func metadata(at url: URL) async throws -> (
    title: String, author: String, cover: Data?
  ) {
    let archive = try await Archive(url: url, accessMode: .read)
    let entries = try await archive.entries()
    guard entries.count <= 100_000 else { throw LibraryError.message("电子书包含过多文件") }
    var total: UInt64 = 0
    for entry in entries {
      try validatePath(entry.path)
      guard entry.type != .symlink else { throw LibraryError.message("电子书不能包含符号链接") }
      total += entry.uncompressedSize
      guard total <= 4 * 1024 * 1024 * 1024 else { throw LibraryError.message("电子书解压内容过大") }
    }
    let container = try EPUBMetadataParser.read(
      await read(archive, path: "META-INF/container.xml", limit: 1_048_576))
    guard !container.rootfile.isEmpty else { throw LibraryError.message("电子书未声明内容目录") }
    let metadata = try EPUBMetadataParser.read(await read(archive, path: container.rootfile))
    let base = (container.rootfile as NSString).deletingLastPathComponent
    let coverPath = base.isEmpty ? metadata.coverHref : base + "/" + metadata.coverHref
    let cover =
      metadata.coverHref.isEmpty
      ? nil : try? await read(archive, path: coverPath, limit: 20 * 1024 * 1024)
    return (metadata.title, metadata.author, cover)
  }
}

// TXT 先解码再生成固定分章，阅读副本一经入库不因后续升级重新生成。
public enum TextBookConverter {
  public struct Chapter: Equatable, Sendable {
    public let title: String
    public let text: String
  }
  public static func decode(_ data: Data, encoding: String? = nil) throws -> String {
    guard !data.isEmpty else { throw LibraryError.message("文本文件为空") }
    guard data.count <= 128 * 1024 * 1024 else { throw LibraryError.message("TXT 超过 128 MB，请先分卷") }
    var selected = encoding
    if selected == nil {
      if data.starts(with: [0xff, 0xfe]) {
        selected = "UTF-16LE"
      } else if data.starts(with: [0xfe, 0xff]) {
        selected = "UTF-16BE"
      } else if let result = String(data: data, encoding: .utf8), !result.contains("\0") {
        return result.replacingOccurrences(of: "\u{feff}", with: "")
      } else {
        selected = "GB18030"
      }
    }
    let decoded: String? = data.withUnsafeBytes { bytes in
      var length=0
      guard let address = bytes.baseAddress,
        let converted = miolib_decode_text(
          address.assumingMemoryBound(to: CChar.self), data.count, selected!, &length)
      else { return nil }
      defer { free(converted) }
      return String(data:Data(bytes:converted,count:length),encoding:.utf8)
    }
    guard let decoded, !decoded.contains("\0") else {
      throw LibraryError.message("无法识别文字编码，请选择 UTF-8、UTF-16 或 GB18030 后重试")
    }
    return decoded.replacingOccurrences(of: "\u{feff}", with: "")
  }
  public static func chapters(_ text: String) -> [Chapter] {
    let pattern =
      #"^\s*(第[零〇一二三四五六七八九十百千万两0-9]+[章节卷回部篇].{0,60}|[Cc][Hh][Aa][Pp][Tt][Ee][Rr]\s+\d+.{0,60})\s*$"#
    let regex = try! NSRegularExpression(pattern: pattern)
    var output: [Chapter] = []
    var title = "正文"
    var lines: [String] = []
    var count = 0
    for line in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
      of: "\r", with: "\n"
    ).components(separatedBy: "\n").flatMap(splitLongLine) {
      let heading =
        line.count <= 90
        && regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
      if heading || count > 50_000 {
        if !lines.isEmpty {
          output.append(Chapter(title: title, text: lines.joined(separator: "\n")))
          lines = []
          count = 0
        }
        title = heading ? line.trimmingCharacters(in: .whitespaces) : "\(title) · 续"
      }
      lines.append(line)
      count += line.count
    }
    if !lines.isEmpty { output.append(Chapter(title: title, text: lines.joined(separator: "\n"))) }
    return output
  }
  // 过长的单段也切成稳定片段，避免数兆字的单个 DOM 段落拖慢排版。
  private static func splitLongLine(_ line:String)->[String]{
    guard line.count>8000 else{return [line]}
    var output:[String]=[];var start=line.startIndex
    while start<line.endIndex{let end=line.index(start,offsetBy:8000,limitedBy:line.endIndex) ?? line.endIndex;output.append(String(line[start..<end]));start=end}
    return output
  }
  public static func convert(source: URL, destination: URL, title: String, encoding: String? = nil)
    async throws
  {
    guard (try source.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)<=128*1024*1024 else{throw LibraryError.message("TXT 超过 128 MB，请先分卷")}
    let text = try decode(Data(contentsOf: source), encoding: encoding)
    let chapters = chapters(text)
    let archive = try await Archive(url: destination, accessMode: .create)
    try await EbookArchive.add(
      archive, path: "mimetype", data: Data("application/epub+zip".utf8), stored: true)
    try await EbookArchive.add(
      archive, path: "META-INF/container.xml",
      data: Data(
        "<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"
          .utf8))
    var manifest = ""
    var spine = ""
    var nav = ""
    for (index, chapter) in chapters.enumerated() {
      try Task.checkCancellation()
      let filename = "chapter\(index).xhtml"
      manifest +=
        "<item id=\"c\(index)\" href=\"\(filename)\" media-type=\"application/xhtml+xml\"/>"
      spine += "<itemref idref=\"c\(index)\"/>"
      nav += "<li><a href=\"\(filename)\">\(escape(chapter.title))</a></li>"
      let body = chapter.text.components(separatedBy: "\n").map { "<p>\(escape($0))</p>" }.joined()
      let html =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"zh\"><head><title>\(escape(chapter.title))</title><style>p{text-indent:2em;margin:.6em 0;overflow-wrap:break-word}body{line-height:1.6}</style></head><body>\(body)</body></html>"
      try await EbookArchive.add(archive, path: "OEBPS/\(filename)", data: Data(html.utf8))
    }
    let opf =
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?><package version=\"3.0\" unique-identifier=\"bookid\" xmlns=\"http://www.idpf.org/2007/opf\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"bookid\">urn:sha256:\(FileFingerprint.hash(Data(text.utf8)))</dc:identifier><dc:title>\(escape(title))</dc:title><dc:language>zh</dc:language><meta property=\"dcterms:modified\">2026-01-01T00:00:00Z</meta></metadata><manifest>\(manifest)<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/></manifest><spine>\(spine)</spine></package>"
    try await EbookArchive.add(archive, path: "OEBPS/content.opf", data: Data(opf.utf8))
    let navigation =
      "<?xml version=\"1.0\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>目录</title></head><body><nav epub:type=\"toc\"><ol>\(nav)</ol></nav></body></html>"
    try await EbookArchive.add(archive, path: "OEBPS/nav.xhtml", data: Data(navigation.utf8))
  }
  static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }
}

// Kindle 解压在原生 C 层完成；不接受 DRM、KFX 或仅更名的未知格式。
public enum KindleBookConverter {
  public static func convert(source: URL, destination: URL) async throws {
    guard (try source.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)<=64*1024*1024 else{throw LibraryError.message("MOBI / AZW3 超过 64 MB，请先分卷或转换为 EPUB")}
    guard let mobi = mobi_init() else { throw LibraryError.message("无法分配 Kindle 转换内存") }
    defer { mobi_free(mobi) }
    let loaded = mobi_load_filename(mobi, source.path)
    guard loaded == MOBI_SUCCESS else {
      throw LibraryError.message("无法读取 MOBI / AZW3，文件可能损坏或受 DRM 保护（\(loaded.rawValue)）")
    }
    guard !mobi_is_encrypted(mobi) else { throw LibraryError.message("此 Kindle 文件受 DRM 保护，无法导入") }
    guard let raw = mobi_init_rawml(mobi) else { throw LibraryError.message("无法分配 Kindle 内容内存") }
    defer { mobi_free_rawml(raw) }
    guard mobi_parse_rawml(raw, mobi) == MOBI_SUCCESS else {
      throw LibraryError.message("无法恢复 Kindle 内容或目录")
    }
    try Task.checkCancellation()
    let archive = try await Archive(url: destination, accessMode: .create)
    try await EbookArchive.add(
      archive, path: "mimetype", data: Data("application/epub+zip".utf8), stored: true)
    try await EbookArchive.add(
      archive, path: "META-INF/container.xml",
      data: Data(
        "<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"
          .utf8))
    var hasOPF = false
    for (first, prefix, skipFirst) in [
      (raw.pointee.markup, "part", false), (raw.pointee.flow, "flow", true),
      (raw.pointee.resources, "resource", false),
    ] {
      var current = skipFirst ? first?.pointee.next : first
      while let part = current {
        try Task.checkCancellation()
        let value = part.pointee
        let metadata = mobi_get_filemeta_by_type(value.type)
        if value.size > 0, let bytes = value.data {
          let name: String
          if value.type == T_OPF {
            name = "content.opf"
            hasOPF = true
          } else {
            var ext = metadata.extension
            let suffix = withUnsafeBytes(of: &ext) { bytes in
              String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            name = String(format: "%@%05lu.%@", prefix, value.uid, suffix)
          }
          try await EbookArchive.add(
            archive, path: "OEBPS/\(name)", data: Data(bytes: bytes, count: value.size))
        }
        current = value.next
      }
    }
    guard hasOPF else { throw LibraryError.message("此 Kindle 文件不能转换为 EPUB，未找到内容清单") }
  }
}
