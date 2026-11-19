import Foundation

// 文件格式使用原始扩展名；TXT 与 Kindle 文件另有稳定的 EPUB 阅读副本。
public enum BookFormat: String, Codable, CaseIterable, Sendable {
  case epub, txt, pdf, mobi, azw3, web
  // 网页书籍由收藏入口创建，文件导入仍只接受原来的五种格式。
  public var label: String { self == .web ? "网页" : rawValue.uppercased() }
  public static func detect(_ url: URL) throws -> BookFormat {
    guard let format = BookFormat(rawValue: url.pathExtension.lowercased()), format != .web else {
      throw LibraryError.message("不支持此格式：\(url.pathExtension)")
    }
    return format
  }
}

// 书籍 ID 与文件名、显示标题分离，改名和移动不会破坏笔记或进度。
public struct Book: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var folderID: UUID?
  public var originalTitle: String
  public var customTitle: String?
  public var author: String
  public var format: BookFormat
  public var originalPath: String
  public var readingPath: String
  public var fingerprint: String
  public var coverPath: String?
  public var customCoverPath: String?
  public var importedAt: Date
  public var lastOpenedAt: Date?
  public var progress: Double
  public var isFavorite: Bool
  public var isFinished: Bool
  public var deletedAt: Date?
  public var position: ReadingPosition?
  // 可选字段兼容旧书库；未提取正文时阅读路径与链接描述文件相同。
  public var webURL: URL?
  // 每本网页书独立记住阅读模式。旧书目没有这一字段时打开原网页。
  public var webReaderEnabled: Bool?
  public var webSnapshotDate: Date?
  // 可选章节清单兼容 1.9.0 的单页正文；各章资源路径一经保存就保持稳定。
  public var webChapters: [WebBookChapter]?
  // 已下载但尚未并入阅读副本的章节随书目持久化，中途退出后可以继续。
  public var webPendingChapters: [WebBookChapter]?
  public var webCacheCompleted: Bool?
  // 可识别的卷目录与离线选择分别保存。没有选择记录的旧书延续整本缓存。
  public var webVolumes: [WebBookVolume]?
  public var webVolumeIDs: [String]?
  // 修改选择后让旧下载失效，并保留删卷时的资源定位供以后重新下载。
  var webCacheRevision: UUID?
  var webRemovedChapterPrefixes: [String: String]?
  public var hasWebReadingCopy: Bool { format == .web && readingPath != originalPath }
  // 所有本地资源共用同一清单，备份、恢复和改链清理不会漏掉已缓存的章节。
  public var assetPaths: [String] {
    [originalPath, readingPath] + [coverPath, customCoverPath].compactMap { $0 }
      + (webChapters ?? []).map(\.readingPath) + (webPendingChapters ?? []).map(\.readingPath)
  }
  public var title: String { customTitle ?? originalTitle }
  public var effectiveCover: String? { customCoverPath ?? coverPath }
  public init(
    id: UUID = UUID(), title: String, author: String = "", format: BookFormat,
    originalPath: String, readingPath: String, fingerprint: String, folderID: UUID? = nil
  ) {
    self.id = id
    self.folderID = folderID
    originalTitle = title
    self.author = author
    self.format = format
    self.originalPath = originalPath
    self.readingPath = readingPath
    self.fingerprint = fingerprint
    importedAt = Date()
    progress = 0
    isFavorite = false
    isFinished = false
  }
}

// 根目录使用 nil；文件夹属于书库逻辑层，不直接重命名磁盘上的书籍。
public struct LibraryFolder: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var parentID: UUID?
  public var title: String
  public var coverPath: String?
  public init(id: UUID = UUID(), parentID: UUID? = nil, title: String, coverPath: String? = nil) {
    self.id = id
    self.parentID = parentID
    self.title = title
    self.coverPath = coverPath
  }
}

// EPUB 保存完整 Readium Locator JSON；PDF 使用页码和归一化页内坐标。
public struct ReadingPosition: Codable, Equatable, Sendable {
  public var locatorJSON: String?
  public var page: Int?
  public var x: Double?
  public var y: Double?
  public init(locatorJSON: String? = nil, page: Int? = nil, x: Double? = nil, y: Double? = nil) {
    self.locatorJSON = locatorJSON
    self.page = page
    self.x = x
    self.y = y
  }
}

// 标注统一保存摘录、颜色和位置；矩形数组供 PDF 跨行高亮恢复使用。
public enum AnnotationKind: String, Codable, Sendable { case bookmark, highlight, note }
public struct PageRect: Codable, Equatable, Sendable {
  public var page: Int
  public var x: Double, y: Double, width: Double, height: Double
  public init(page: Int, x: Double, y: Double, width: Double, height: Double) {
    self.page = page
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}
public struct Annotation: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var bookID: UUID
  public var kind: AnnotationKind
  public var position: ReadingPosition
  public var quote: String
  public var note: String
  public var color: String
  public var chapter: String
  public var rects: [PageRect]
  public var createdAt: Date
  public init(
    id: UUID = UUID(), bookID: UUID, kind: AnnotationKind, position: ReadingPosition,
    quote: String = "", note: String = "", color: String = "yellow", chapter: String = "",
    rects: [PageRect] = []
  ) {
    self.id = id
    self.bookID = bookID
    self.kind = kind
    self.position = position
    self.quote = quote
    self.note = note
    self.color = color
    self.chapter = chapter
    self.rects = rects
    createdAt = Date()
  }
}

// 传输任务持久化到数据库，意外退出后处理中任务回到可重试状态。
public enum ImportState: String, Codable, Sendable {
  case queued, processing, completed, failed, cancelled, duplicate
}
public struct ImportJob: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var stagedPath: String
  public var folderID: UUID?
  public var state: ImportState
  public var detail: String
  public var bookID: UUID?
  public var encoding: String?
  // 外部传书的元数据和摘要可选，旧版本任务仍能直接解码并重试。
  public var sourceTitle: String?
  public var sourceAuthor: String?
  public var sourceFingerprint: String?
  public init(
    id: UUID = UUID(), name: String, stagedPath: String, folderID: UUID? = nil,
    encoding: String? = nil
  ) {
    self.id = id
    self.name = name
    self.stagedPath = stagedPath
    self.folderID = folderID
    self.encoding = encoding
    state = .queued
    detail = "等待导入"
  }
}

// 偏好使用可迁移的 Codable 数据，备份包含阅读设置与书架显示方式。
public enum ReaderTheme: String, Codable, CaseIterable, Sendable {
  case system, light, dark, paper
  public var label: String {
    switch self {
    case .system: "跟随系统"
    case .light: "浅色"
    case .dark: "深色"
    case .paper: "暖纸色"
    }
  }
}

// 书内注释的打开方式随阅读偏好保存。
public enum ReaderFootnoteMode: String, Codable, CaseIterable, Sendable {
  case preview, jump

  public var label: String {
    switch self { case .preview: "小窗预览"; case .jump: "直接跳转" }
  }
}

// 仅保留列表与封面两种布局，两者共享编辑能力。
public enum ShelfLayout: String, Codable, CaseIterable, Sendable {
  case list, covers
  // 旧版数据库及备份中的网格布局迁移为封面，其他偏好仍正常解码。
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    if value == "grid" {
      self = .covers
    } else if let layout = Self(rawValue: value) {
      self = layout
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "未知书架布局：\(value)")
    }
  }
  // 新保存的偏好只写入当前支持的布局，不再产生旧网格值。
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
  // 两个布局选择入口共用名称与图标，避免继续显示旧网格选项。
  public var label: String {
    switch self { case .list: "列表"; case .covers: "封面" }
  }
  public var symbol: String {
    switch self { case .list: "list.bullet"; case .covers: "rectangle.grid.2x2" }
  }
}

// 封面样式独立于列表/封面布局，旧版偏好默认保留已设置的单张封面。
public enum ShelfCoverStyle: String, Codable, CaseIterable, Sendable {
  case single, mosaic
  // 书架菜单与设置页共用可切换选项，不覆盖书架原有封面文件。
  public var label: String {
    switch self { case .single: "单张封面"; case .mosaic: "四宫格" }
  }
  public var symbol: String {
    switch self { case .single: "book.closed"; case .mosaic: "square.grid.2x2" }
  }
}

// 排序跟随书库设置保存，切换目录、重新启动和恢复备份后仍保留选择。
public enum BookSort: String, Codable, CaseIterable, Sendable {
  case recentlyRead, title, imported
  public var label: String {
    switch self { case .recentlyRead: "最近阅读"; case .title: "书名"; case .imported: "导入时间" }
  }
}
// 界面字体独立于正文排版，系统大小作为基准，避免修改界面时改变阅读字号。
public enum InterfaceTextSize: String, Codable, CaseIterable, Sendable {
  case smaller, system, larger, extraLarge, largest
  public var label: String {
    switch self { case .smaller: "较小"; case .system: "跟随系统"; case .larger: "较大"; case .extraLarge: "更大"; case .largest: "最大" }
  }
  public var offset: Int {
    switch self { case .smaller: -3; case .system: 0; case .larger: 1; case .extraLarge: 2; case .largest: 3 }
  }
  // 控件与留白跟随字号档位缩放，较小档保留至少 44 点的主要点击区域。
  public var layoutScale: Double {
    switch self { case .smaller: 0.75; case .system: 1; case .larger: 1.12; case .extraLarge: 1.24; case .largest: 1.36 }
  }
}
public enum InterfaceFont: String, Codable, CaseIterable, Sendable {
  case system, rounded, serif, monospaced
  public var label: String {
    switch self { case .system: "系统默认"; case .rounded: "圆角"; case .serif: "衬线"; case .monospaced: "等宽" }
  }
}
public struct ReaderPreferences: Codable, Equatable, Sendable {
  public var interfaceTextSize: InterfaceTextSize = .system
  public var interfaceFont: InterfaceFont = .system
  public var theme: ReaderTheme = .system
  public var fontSize: Double = 100
  public var lineHeight: Double = 1.6
  public var margins: Double = 1.5
  public var serif: Bool = false
  public var scroll: Bool = false
  public var footnoteMode: ReaderFootnoteMode = .preview
  public var shelfLayout: ShelfLayout = .list
  // 四宫格仅改变显示方式，原有书架封面仍独立保存。
  public var shelfCoverStyle: ShelfCoverStyle = .single
  public var bookSort: BookSort = .recentlyRead
  // 个人资料只保存在本机，头像使用书库内的相对路径并随完整备份迁移。
  public var profileName: String = "读者"
  public var profileBio: String = "让阅读成为日常"
  public var profileAvatarPath: String?
  // 旧字段仅用于迁移及旧调用兼容，避免更新后把封面视图重置为列表。
  public var grid: Bool {
    get { shelfLayout != .list }
    set { shelfLayout = newValue ? .covers : .list }
  }
  public init() {}

  private enum CodingKeys: String, CodingKey {
    case interfaceTextSize, interfaceFont
    case theme, fontSize, lineHeight, margins, serif, scroll, grid, shelfLayout, shelfCoverStyle, bookSort
    case footnoteMode
    case profileName, profileBio, profileAvatarPath
  }
  // 逐字段提供默认值，旧版备份没有新增字段时也能完整恢复。
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    interfaceTextSize = try values.decodeIfPresent(InterfaceTextSize.self, forKey: .interfaceTextSize) ?? .system
    interfaceFont = try values.decodeIfPresent(InterfaceFont.self, forKey: .interfaceFont) ?? .system
    theme = try values.decodeIfPresent(ReaderTheme.self, forKey: .theme) ?? .system
    fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 100
    lineHeight = try values.decodeIfPresent(Double.self, forKey: .lineHeight) ?? 1.6
    margins = try values.decodeIfPresent(Double.self, forKey: .margins) ?? 1.5
    serif = try values.decodeIfPresent(Bool.self, forKey: .serif) ?? false
    scroll = try values.decodeIfPresent(Bool.self, forKey: .scroll) ?? false
    // 旧版偏好与备份缺少此字段时，默认在原页预览。
    footnoteMode = try values.decodeIfPresent(ReaderFootnoteMode.self, forKey: .footnoteMode) ?? .preview
    let oldGrid = try values.decodeIfPresent(Bool.self, forKey: .grid) ?? false
    shelfLayout = try values.decodeIfPresent(ShelfLayout.self, forKey: .shelfLayout) ?? (oldGrid ? .covers : .list)
    // 兼容旧版数据库与备份，缺少样式字段时继续使用单张封面。
    shelfCoverStyle = try values.decodeIfPresent(ShelfCoverStyle.self, forKey: .shelfCoverStyle) ?? .single
    bookSort = try values.decodeIfPresent(BookSort.self, forKey: .bookSort) ?? .recentlyRead
    profileName = try values.decodeIfPresent(String.self, forKey: .profileName) ?? "读者"
    profileBio = try values.decodeIfPresent(String.self, forKey: .profileBio) ?? "让阅读成为日常"
    profileAvatarPath = try values.decodeIfPresent(String.self, forKey: .profileAvatarPath)
  }
  // 保留 grid 键，让旧版本读取新备份时仍能识别基本布局。
  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(interfaceTextSize, forKey: .interfaceTextSize)
    try values.encode(interfaceFont, forKey: .interfaceFont)
    try values.encode(theme, forKey: .theme)
    try values.encode(fontSize, forKey: .fontSize)
    try values.encode(lineHeight, forKey: .lineHeight)
    try values.encode(margins, forKey: .margins)
    try values.encode(serif, forKey: .serif)
    try values.encode(scroll, forKey: .scroll)
    try values.encode(footnoteMode, forKey: .footnoteMode)
    try values.encode(grid, forKey: .grid)
    try values.encode(shelfLayout, forKey: .shelfLayout)
    // 样式随偏好存入数据库，并由现有完整备份流程一并保存。
    try values.encode(shelfCoverStyle, forKey: .shelfCoverStyle)
    try values.encode(bookSort, forKey: .bookSort)
    try values.encode(profileName, forKey: .profileName)
    try values.encode(profileBio, forKey: .profileBio)
    try values.encodeIfPresent(profileAvatarPath, forKey: .profileAvatarPath)
  }
}

// 统一错误始终带有可向用户展示的中文原因。
public enum LibraryError: LocalizedError {
  case message(String)
  case duplicate(UUID)
  public var errorDescription: String? {
    switch self {
    case .message(let value): value
    case .duplicate: "书库中已有相同文件"
    }
  }
}

// JSON 编解码器按需创建，避免跨并发任务共享可变实例。
public enum LibraryJSON {
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .deferredToDate
    return try encoder.encode(value)
  }
  public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
    return try decoder.decode(type, from: data)
  }
}

// 所有持久化路径相对于书库，恢复到其他设备时无需重写绝对路径。
public struct LibraryPaths: Sendable {
  public let root: URL
  public init(root: URL) throws {
    self.root = root.standardizedFileURL
    for directory in ["Originals", "Reading", "Covers", "Staging"] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
  }
  public func url(_ relative: String) throws -> URL {
    let result = root.appendingPathComponent(relative).standardizedFileURL
    guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."),
      result.path.hasPrefix(root.path + "/"), !relative.contains("\\")
    else {
      throw LibraryError.message("无效的书库文件路径")
    }
    return result
  }
}
