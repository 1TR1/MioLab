import Foundation
import XCTest
@testable import MioLibCore

// 更新不能丢失旧版偏好，排序和受支持的布局必须随数据库及备份往返保留。
final class ReaderInterfaceTests: XCTestCase {
  func testLegacyPreferencesKeepCoverLayoutAndReadingValues() throws {
    let data = Data(#"{"theme":"paper","fontSize":135,"lineHeight":1.8,"margins":2,"serif":true,"scroll":true,"grid":true}"#.utf8)
    let prefs = try LibraryJSON.decode(ReaderPreferences.self, from: data)
    XCTAssertEqual(prefs.shelfLayout, .covers)
    XCTAssertEqual(prefs.bookSort, .recentlyRead)
    XCTAssertEqual(prefs.fontSize, 135)
    XCTAssertEqual(prefs.theme, .paper)
    XCTAssertTrue(prefs.scroll)
    XCTAssertTrue(prefs.serif)
    XCTAssertEqual(try LibraryJSON.decode(ReaderPreferences.self, from: Data("{}".utf8)), ReaderPreferences())
  }

  // 删除网格选项后，旧枚举值优先于旧布尔字段，且不能导致其余设置丢失。
  func testRemovedGridLayoutMigratesWithoutResettingPreferences() throws {
    for oldGrid in [false, true] {
      let data = Data("""
        {"shelfLayout":"grid","grid":\(oldGrid),"bookSort":"title","theme":"paper",
         "fontSize":150,"interfaceTextSize":"larger","interfaceFont":"rounded","profileName":"小书虫"}
        """.utf8)
      let prefs = try LibraryJSON.decode(ReaderPreferences.self, from: data)
      XCTAssertEqual(prefs.shelfLayout, .covers)
      XCTAssertEqual(prefs.bookSort, .title)
      XCTAssertEqual(prefs.theme, .paper)
      XCTAssertEqual(prefs.fontSize, 150)
      XCTAssertEqual(prefs.interfaceTextSize, .larger)
      XCTAssertEqual(prefs.interfaceFont, .rounded)
      XCTAssertEqual(prefs.profileName, "小书虫")
      let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryJSON.encode(prefs)) as? [String: Any])
      XCTAssertEqual(encoded["shelfLayout"] as? String, "covers")
    }
    // 未知损坏值仍报告错误，不能借迁移静默覆盖其他无效设置。
    XCTAssertThrowsError(try LibraryJSON.decode(ShelfLayout.self, from: Data(#""invalid""#.utf8)))
  }

  // 在磁盘中写入旧版网格设置，确认升级读取、重新保存与备份恢复均能保留偏好。
  func testLegacyGridDatabaseReopensAndBacksUpAsCovers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let libraryRoot = root.appendingPathComponent("source")
    _ = try LibraryPaths(root: libraryRoot)
    let data = Data(#"{"shelfLayout":"grid","bookSort":"imported","fontSize":175,"profileName":"旧版读者"}"#.utf8)
    do {
      let database = try SQLiteDatabase(url: libraryRoot.appendingPathComponent("library.sqlite"))
      try database.run("INSERT INTO settings(id,payload) VALUES('preferences',?)", [.blob(data)])
    }
    let source = try LibraryRepository(root: libraryRoot)
    let migrated = try await source.preferences()
    XCTAssertEqual(migrated.shelfLayout, .covers)
    XCTAssertEqual(migrated.bookSort, .imported)
    XCTAssertEqual(migrated.fontSize, 175)
    XCTAssertEqual(migrated.profileName, "旧版读者")
    try await source.savePreferences(migrated)
    let reopened = try LibraryRepository(root: libraryRoot)
    let saved = try await reopened.preferences()
    XCTAssertEqual(saved, migrated)
    let backup = root.appendingPathComponent("legacy-grid.miolib")
    try await source.exportBackup(to: backup)
    let restored = try LibraryRepository(root: root.appendingPathComponent("restored"))
    try await restored.restoreBackup(from: backup)
    let recovered = try await restored.preferences()
    XCTAssertEqual(recovered, migrated)
  }

  // 封面布局与排序在真实数据库重开及完整备份恢复后保持一致。
  func testSortAndLayoutPersistAcrossReopenAndBackup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try LibraryRepository(root: root.appendingPathComponent("source"))
    var prefs = ReaderPreferences()
    prefs.shelfLayout = .covers
    prefs.bookSort = .title
    prefs.fontSize = 125
    try await source.savePreferences(prefs)
    let reopened = try LibraryRepository(root: root.appendingPathComponent("source"))
    let stored = try await reopened.preferences()
    XCTAssertEqual(stored, prefs)
    let backup = root.appendingPathComponent("library.miolib")
    try await source.exportBackup(to: backup)
    let restored = try LibraryRepository(root: root.appendingPathComponent("restored"))
    try await restored.restoreBackup(from: backup)
    let result = try await restored.preferences()
    XCTAssertEqual(result, prefs)
  }

  // 空页、单页、越界与输入错误都不允许请求无效的页面索引。
  func testPageNavigationBoundsAndInput() {
    XCTAssertEqual(ReaderPageNavigation.index(1, count: 1), 0)
    XCTAssertEqual(ReaderPageNavigation.index(100, count: 10), 9)
    XCTAssertEqual(ReaderPageNavigation.index(-10, count: 10), 0)
    XCTAssertEqual(ReaderPageNavigation.parse(" 3 ", count: 3), 3)
    for text in ["", "0", "4", "1.2", "hello", "999999999999999999999999"] {
      XCTAssertNil(ReaderPageNavigation.parse(text, count: 3))
    }
    XCTAssertNil(ReaderPageNavigation.parse("1", count: 0))
  }

  // 字号和小数排版值在格点附近按最近值吸附，异常数值不会泄漏给引擎。
  func testMagneticFormattingValues() {
    XCTAssertEqual(ReaderSnap.value(127, in: 75...200, step: 5), 125)
    XCTAssertEqual(ReaderSnap.value(128, in: 75...200, step: 5), 130)
    XCTAssertEqual(ReaderSnap.value(1.64, in: 1.2...2.4, step: 0.1), 1.6)
    XCTAssertEqual(ReaderSnap.value(1.66, in: 1.2...2.4, step: 0.1), 1.7)
    XCTAssertEqual(ReaderSnap.value(3.1, in: 0.5...3, step: 0.1), 3)
    XCTAssertEqual(ReaderSnap.value(.nan, in: 75...200, step: 5), 75)
  }

  // 界面字体往返数据库和备份后保留，独立修改不能改变正文字号或字体选择。
  func testInterfaceTypographyIsIndependentAndBackedUp() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try LibraryRepository(root: root.appendingPathComponent("source"))
    var prefs = ReaderPreferences()
    prefs.fontSize = 125
    prefs.serif = true
    prefs.lineHeight = 1.8
    prefs.interfaceTextSize = .extraLarge
    prefs.interfaceFont = .rounded
    try await source.savePreferences(prefs)
    let reopened = try LibraryRepository(root: root.appendingPathComponent("source"))
    let saved = try await reopened.preferences()
    XCTAssertEqual(saved, prefs)
    XCTAssertEqual(saved.fontSize, 125)
    XCTAssertTrue(saved.serif)
    let backup = root.appendingPathComponent("interface.miolib")
    try await source.exportBackup(to: backup)
    let restored = try LibraryRepository(root: root.appendingPathComponent("restored"))
    try await restored.restoreBackup(from: backup)
    let recovered = try await restored.preferences()
    XCTAssertEqual(recovered, prefs)
    var reset = recovered
    reset.interfaceTextSize = .system
    reset.interfaceFont = .system
    XCTAssertEqual(reset.fontSize, recovered.fontSize)
    XCTAssertEqual(reset.serif, recovered.serif)
    XCTAssertEqual(reset.lineHeight, recovered.lineHeight)
  }
}
