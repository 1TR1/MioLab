import Foundation
import XCTest
@testable import MioLibCore

// 以确定的日期和封面区分样书，验证四宫格来源、空格以及偏好保存。
final class ShelfCoverTests: XCTestCase {
  private func book(_ index: Int, folderID: UUID?) -> Book {
    var result = Book(title: String(format: "样书 %02d", index), format: .epub,
                      originalPath: "original/\(index).epub", readingPath: "original/\(index).epub",
                      fingerprint: "fixture-\(index)", folderID: folderID)
    result.importedAt = Date(timeIntervalSince1970: Double(index) * 100)
    result.coverPath = "covers/\(index).jpg"
    return result
  }

  // 0 至 6 本书均固定四格；不复制已有图片来填充空位，超过四本只显示前四本。
  func testEmptyAndPartialShelvesKeepFourSlots() {
    let folderID = UUID()
    let books = (1...6).map { book($0, folderID: folderID) }
    for count in 0...6 {
      let slots = ShelfCoverSelection.slots(folderID: folderID, books: Array(books.prefix(count)), sort: .title)
      let expected: [String?] = (0..<4).map { $0 < count ? "covers/\($0 + 1).jpg" : nil }
      XCTAssertEqual(slots, expected)
    }
  }

  // 直属书籍按当前排序取封面；缺封面保留原格，自定义封面优先，其他书架与已删书籍不混入。
  func testScopeSortingAndMissingCovers() {
    let folderID = UUID()
    var first = book(1, folderID: folderID)
    first.lastOpenedAt = Date(timeIntervalSince1970: 1000)
    first.customCoverPath = "covers/custom.jpg"
    var second = book(2, folderID: folderID)
    second.coverPath = nil
    let third = book(3, folderID: folderID)
    var deleted = book(0, folderID: folderID)
    deleted.deletedAt = Date()
    let child = LibraryFolder(parentID: folderID, title: "子书架")
    let books = [third, deleted, book(0, folderID: child.id), book(0, folderID: UUID()),
                 second, book(0, folderID: nil), first]
    XCTAssertEqual(ShelfCoverSelection.slots(folderID: folderID, books: books, sort: .title),
                   ["covers/custom.jpg", nil, "covers/3.jpg", nil])
    XCTAssertEqual(ShelfCoverSelection.slots(folderID: folderID, books: books, sort: .imported),
                   ["covers/3.jpg", nil, "covers/custom.jpg", nil])
    XCTAssertEqual(ShelfCoverSelection.slots(folderID: folderID, books: books, sort: .recentlyRead),
                   ["covers/custom.jpg", "covers/3.jpg", nil, nil])
    // 同日期、同标题时重新加载的输入次序不能改变四宫格。
    var tied = first
    tied.id = UUID()
    tied.customCoverPath = "covers/tied.jpg"
    let forward = ShelfCoverSelection.slots(folderID: folderID, books: [first, tied], sort: .recentlyRead)
    let reverse = ShelfCoverSelection.slots(folderID: folderID, books: [tied, first], sort: .recentlyRead)
    XCTAssertEqual(forward, reverse)
  }

  // 旧版偏好未包含新字段时保留单张封面，同时不重置布局和阅读主题。
  func testLegacyPreferencesDefaultToSingleCover() throws {
    let data = Data(#"{"shelfLayout":"covers","theme":"paper","fontSize":150}"#.utf8)
    let preferences = try LibraryJSON.decode(ReaderPreferences.self, from: data)
    XCTAssertEqual(preferences.shelfCoverStyle, .single)
    XCTAssertEqual(preferences.shelfLayout, .covers)
    XCTAssertEqual(preferences.theme, .paper)
    XCTAssertEqual(preferences.fontSize, 150)
  }

  // 两种样式经过真实 SQLite 重开和备份恢复均保留，原先设置的书架封面文件也不受影响。
  func testStylePersistsAndKeepsOriginalFolderCover() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try LibraryRepository(root: root.appendingPathComponent("source"))
    let coverData = Data([255, 216, 1, 2, 3, 255, 217])
    let cover = try await source.storeCover(coverData)
    let folder = LibraryFolder(title: "保留封面的书架", coverPath: cover)
    try await source.saveFolder(folder)
    for style in ShelfCoverStyle.allCases {
      var preferences = ReaderPreferences()
      preferences.shelfCoverStyle = style
      preferences.shelfLayout = .covers
      preferences.bookSort = .title
      try await source.savePreferences(preferences)
      let reopened = try LibraryRepository(root: root.appendingPathComponent("source"))
      let saved = try await reopened.preferences()
      XCTAssertEqual(saved, preferences)
      let backup = root.appendingPathComponent("\(style.rawValue).miolib")
      try await source.exportBackup(to: backup)
      let restored = try LibraryRepository(root: root.appendingPathComponent(style.rawValue))
      try await restored.restoreBackup(from: backup)
      let recovered = try await restored.preferences()
      XCTAssertEqual(recovered, preferences)
      let restoredFolders = try await restored.folders()
      let restoredCover = try XCTUnwrap(restoredFolders.first?.coverPath)
      XCTAssertEqual(try Data(contentsOf: restored.paths.url(restoredCover)), coverData)
      XCTAssertEqual(try Data(contentsOf: source.paths.url(cover)), coverData)
    }
  }
}
