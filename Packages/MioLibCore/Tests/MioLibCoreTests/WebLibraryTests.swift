import Foundation
import MioZIPFoundation
import XCTest
@testable import MioLibCore

// 网页功能的真实 SQLite、备份及规则边界测试，不访问真实网站或私人书库。
final class WebLibraryTests: XCTestCase {
  // 规范化只合并等价地址，章节、锚点和登录查询参数必须保留。
  func testAddressNormalizationAndRejectedSchemes() throws {
    XCTAssertEqual(try WebAddress.url("  Example.COM:443  ").absoluteString, "https://example.com/")
    XCTAssertEqual(try WebAddress.url("HTTP://Example.com:80/book?p=2#chapter").absoluteString, "http://example.com/book?p=2#chapter")
    XCTAssertEqual(try WebAddress.url("//example.com/novel/1").absoluteString, "https://example.com/novel/1")
    XCTAssertEqual(try WebAddress.url("http://127.0.0.1:8080/read").port, 8080)
    XCTAssertNotEqual(try WebAddress.url("example.com/a#one"), try WebAddress.url("example.com/a#two"))
    for invalid in ["", "javascript:alert(1)", "file:///etc/passwd", "data:text/html,test", "https:///", "https://reader:secret@example.com/", "https://example.com\n/evil", "https://example.com:99999/", "not a url"] {
      XCTAssertThrowsError(try WebAddress.url(invalid), invalid)
    }
  }

  // 重复保存保留 ID，编辑冲突不能覆盖另一收藏；删除和重开数据库均验证实际存储。
  func testBookmarkPersistenceDeduplicationEditingAndDeletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try LibraryRepository(root: root)
    let first = try await repository.saveWebBookmark(address: "Example.com", title: " 原标题 ")
    let duplicate = try await repository.saveWebBookmark(address: "https://example.com:443/", title: "新标题")
    XCTAssertEqual(first.id, duplicate.id)
    XCTAssertEqual(first.createdAt, duplicate.createdAt)
    XCTAssertEqual(duplicate.title, "新标题")
    let second = try await repository.saveWebBookmark(address: "example.com/chapter/2", title: "")
    XCTAssertEqual(second.title, "example.com")
    do {
      _ = try await repository.saveWebBookmark(address: second.url.absoluteString, title: "冲突", id: first.id)
      XCTFail("编辑不能覆盖另一收藏")
    } catch {}
    let edited = try await repository.saveWebBookmark(address: "example.com/chapter/3", title: "第三章", id: first.id)
    XCTAssertEqual(edited.id, first.id)
    try await repository.markWebBookmarkOpened(edited.url)
    let reopened = try LibraryRepository(root: root)
    let bookmarks = try await reopened.webBookmarks()
    XCTAssertEqual(bookmarks.count, 2)
    XCTAssertEqual(bookmarks.first?.id, first.id)
    XCTAssertNotNil(bookmarks.first?.lastOpenedAt)
    try await reopened.deleteWebBookmark(first.id)
    let remaining = try await repository.webBookmarks()
    XCTAssertEqual(remaining.map(\.id), [second.id])
    do {
      _ = try await repository.saveWebBookmark(address: "example.com", title: "已删除", id: first.id)
      XCTFail("编辑已删除的收藏不能悄悄新建")
    } catch {}
  }

  // 维护锁阻止网页写入；无效输入失败后仍可正常使用原有收藏。
  func testInvalidInputAndMaintenancePreserveBookmarks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try LibraryRepository(root: root)
    let saved = try await repository.saveWebBookmark(address: "example.com", title: "正文")
    for address in ["javascript:alert(1)", "https://user:pass@example.com"] {
      do { _ = try await repository.saveWebBookmark(address: address, title: "错误"); XCTFail("应拒绝无效网址") } catch {}
    }
    do { _ = try await repository.saveWebBookmark(address: "example.com", title: String(repeating: "长", count: 501)); XCTFail("应拒绝过长标题") } catch {}
    await repository.setMaintenanceForWebTest(true)
    do { try await repository.deleteWebBookmark(saved.id); XCTFail("维护期间应拒绝删除") } catch {}
    do { try await repository.saveWebPreferences(WebPreferences(blocksAds: false)); XCTFail("维护期间应拒绝写入设置") } catch {}
    await repository.setMaintenanceForWebTest(false)
    let unchanged = try await repository.webBookmarks()
    XCTAssertEqual(unchanged, [saved])
  }

  // 新版备份完整恢复收藏、访问时间与过滤偏好，并替换恢复前的收藏。
  func testWebBookmarksAndFilterBackupRoundTrip() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try LibraryRepository(root: root.appendingPathComponent("source"))
    let bookmark = try await source.saveWebBookmark(address: "example.com/chapter?p=3#reading", title: "阅读第三章")
    try await source.markWebBookmarkOpened(bookmark.url)
    try await source.saveWebPreferences(WebPreferences(blocksAds: false))
    let backup = root.appendingPathComponent("web.miolib")
    try await source.exportBackup(to: backup)
    let target = try LibraryRepository(root: root.appendingPathComponent("target"))
    _ = try await target.saveWebBookmark(address: "other.example.org", title: "旧收藏")
    try await target.restoreBackup(from: backup)
    let expected = try await source.webBookmarks()
    let actual = try await target.webBookmarks()
    let prefs = try await target.webPreferences()
    XCTAssertEqual(actual, expected)
    XCTAssertFalse(prefs.blocksAds)
  }

  // 真正缺少网页字段的 v1 清单仍可恢复，并重置新版本多出的收藏与过滤开关。
  func testLegacyBackupWithoutWebFields() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let backup = root.appendingPathComponent("legacy.miolib")
    let snapshot = BackupManifest(version: 1, books: [], folders: [], annotations: [], preferences: ReaderPreferences(), files: [:])
    try await writeSnapshot(snapshot, to: backup)
    let target = try LibraryRepository(root: root.appendingPathComponent("target"))
    _ = try await target.saveWebBookmark(address: "example.com", title: "待替换")
    try await target.saveWebPreferences(WebPreferences(blocksAds: false))
    try await target.restoreBackup(from: backup)
    let bookmarks = try await target.webBookmarks()
    let prefs = try await target.webPreferences()
    XCTAssertTrue(bookmarks.isEmpty)
    XCTAssertTrue(prefs.blocksAds)
  }

  // 构造重复与脚本收藏的备份，验证拒绝发生在提交前且保留现有数据。
  func testInvalidBackupPreservesLibrary() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = try LibraryRepository(root: root)
    let saved = try await target.saveWebBookmark(address: "example.com", title: "保留")
    let unsafe = WebBookmark(title: "脚本", url: URL(string: "javascript:alert(1)")!)
    for (index, invalid) in [[saved, saved], [unsafe]].enumerated() {
      let backup = root.appendingPathComponent("invalid-\(index).miolib")
      let snapshot = BackupManifest(books: [], folders: [], annotations: [], preferences: ReaderPreferences(), files: [:], webBookmarks: invalid)
      try await writeSnapshot(snapshot, to: backup)
      do { try await target.restoreBackup(from: backup); XCTFail("应拒绝无效备份") } catch {}
      let current = try await target.webBookmarks()
      XCTAssertEqual(current, [saved])
    }
  }

  // 域名边界匹配广告子域，避免误拦含广告域名的文章链接、查询参数及相似主机。
  func testFilterDomainBoundariesAndRuleStructure() throws {
    let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(WebContentFilter.rulesJSON().utf8)) as? [[String: Any]])
    XCTAssertEqual(rules.count, WebContentFilter.domains.count + 1)
    for domain in WebContentFilter.domains {
      let pattern = try NSRegularExpression(pattern: WebContentFilter.pattern(for: domain), options: .caseInsensitive)
      for address in ["https://\(domain)/ad.js", "http://a.b.\(domain):8080/banner"] {
        XCTAssertNotNil(pattern.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)))
      }
      for address in ["https://\(domain).example.org/a", "https://example.org/read?url=https://\(domain)/", "https://not\(domain)/"] {
        XCTAssertNil(pattern.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)))
      }
    }
    for rule in rules.dropLast() {
      let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
      XCTAssertEqual(trigger["load-type"] as? [String], ["third-party"])
    }
    let action = try XCTUnwrap(rules.last?["action"] as? [String: String])
    XCTAssertEqual(action["type"], "css-display-none")
    XCTAssertFalse(try XCTUnwrap(action["selector"]).contains("[class*="))
  }

  // 构造标准 ZIP 清单，执行真实恢复路径而不是只测试 JSON 解码。
  private func writeSnapshot(_ snapshot: BackupManifest, to url: URL) async throws {
    let archive = try await Archive(url: url, accessMode: .create)
    try await EbookArchive.add(archive, path: "manifest.json", data: LibraryJSON.encode(snapshot))
  }
}

// 仅测试扩展可切换维护状态，生产接口不暴露维护锁的写入权限。
private extension LibraryRepository {
  func setMaintenanceForWebTest(_ value: Bool) { maintenance = value }
}
