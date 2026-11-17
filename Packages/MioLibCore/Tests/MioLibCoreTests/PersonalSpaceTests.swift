import Foundation
import XCTest
@testable import MioLibCore

// 个人信息与头像必须随真实备份恢复，同时保留用户原有布局和阅读偏好。
final class PersonalSpaceTests: XCTestCase {
  func testProfileAvatarBackupRestoreAndReset() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try LibraryRepository(root: root.appendingPathComponent("source"))
    var prefs = ReaderPreferences()
    // 资料编辑应保留目前支持的封面布局。
    prefs.shelfLayout = .covers
    prefs.bookSort = .title
    prefs.fontSize = 125
    try await source.savePreferences(prefs)
    let image = Data([255, 216, 4, 5, 6, 255, 217])
    let saved = try await source.updateProfile(name: "  小书虫  ", bio: "读一页，记一页", avatarData: image)
    XCTAssertEqual(saved.profileName, "小书虫")
    XCTAssertEqual(saved.bookSort, .title)
    XCTAssertEqual(saved.shelfLayout, .covers)
    XCTAssertEqual(saved.fontSize, 125)
    let avatar = try XCTUnwrap(saved.profileAvatarPath)
    let backup = root.appendingPathComponent("profile.miolib")
    try await source.exportBackup(to: backup)
    let restored = try LibraryRepository(root: root.appendingPathComponent("restored"))
    try await restored.restoreBackup(from: backup)
    let result = try await restored.preferences()
    XCTAssertEqual(result.profileName, saved.profileName)
    XCTAssertEqual(result.profileBio, saved.profileBio)
    let restoredAvatar = try XCTUnwrap(result.profileAvatarPath)
    XCTAssertNotEqual(restoredAvatar, avatar)
    XCTAssertEqual(try Data(contentsOf: restored.paths.url(restoredAvatar)), image)
    let reset = try await source.updateProfile(name: "小书虫", bio: "新简介", resetAvatar: true)
    XCTAssertNil(reset.profileAvatarPath)
    XCTAssertFalse(FileManager.default.fileExists(atPath: try source.paths.url(avatar).path))
    XCTAssertEqual(try Data(contentsOf: restored.paths.url(restoredAvatar)), image)
  }

  // 校验失败不改动资料和头像；从备份带来的共享资源也不能被头像回收误删。
  func testInvalidProfileAndSharedAvatarPreserveAssets() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try LibraryRepository(root: root)
    let saved = try await source.updateProfile(name: "读者", bio: "简介", avatarData: Data([1, 2, 3]))
    do {
      _ = try await source.updateProfile(name: "   ", bio: "错误", avatarData: Data([4]))
      XCTFail("空昵称必须拒绝")
    } catch {}
    let unchanged = try await source.preferences()
    XCTAssertEqual(unchanged, saved)
    let avatar = try XCTUnwrap(saved.profileAvatarPath)
    let book = Book(title: "共享资源", format: .epub, originalPath: avatar, readingPath: avatar,
                    fingerprint: FileFingerprint.hash(Data("shared".utf8)))
    try await source.insert(book)
    _ = try await source.updateProfile(name: "新名字", bio: "", resetAvatar: true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: try source.paths.url(avatar).path))
  }

  // 少量字号格点支持旧版中间值、按钮边界以及非有限输入。
  func testSparseFormattingAnchorsAndAdjustment() {
    XCTAssertEqual(ReaderSnap.fontSizes.count, 6)
    XCTAssertEqual(ReaderSnap.closest(128, to: ReaderSnap.fontSizes), 125)
    XCTAssertEqual(ReaderSnap.closest(.nan, to: ReaderSnap.fontSizes), 75)
    XCTAssertEqual(ReaderSnap.adjacent(135, in: ReaderSnap.fontSizes, increasing: true), 150)
    XCTAssertEqual(ReaderSnap.adjacent(135, in: ReaderSnap.fontSizes, increasing: false), 125)
    XCTAssertEqual(ReaderSnap.adjacent(200, in: ReaderSnap.fontSizes, increasing: true), 200)
    XCTAssertEqual(ReaderSnap.adjacent(75, in: ReaderSnap.fontSizes, increasing: false), 75)
    // 等距轨道在相邻锚点中间切换，防止字号触点再次出现大小不一的间隔。
    XCTAssertEqual(ReaderSnap.closest(112.4, to: ReaderSnap.fontSizes), 100)
    XCTAssertEqual(ReaderSnap.closest(112.6, to: ReaderSnap.fontSizes), 125)
    XCTAssertEqual(ReaderSnap.adjacent(100, in: ReaderSnap.fontSizes, increasing: true), 125)
    XCTAssertEqual(ReaderSnap.adjacent(100, in: ReaderSnap.fontSizes, increasing: false), 75)
  }
}
