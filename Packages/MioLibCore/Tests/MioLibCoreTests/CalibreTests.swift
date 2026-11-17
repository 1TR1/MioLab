import Foundation
import XCTest
@testable import MioLibCore

// 解析测试覆盖真实 OPDS 的相对地址、命名空间、多格式、分页与中文搜索编码。
final class CalibreTests: XCTestCase {
  func testAddressNormalizationAndCredentialScope() throws {
    let connection = try CalibreConnection(address: "192.168.1.8:8080/books/")
    XCTAssertEqual(connection.catalogURL.absoluteString, "http://192.168.1.8:8080/books/opds")
    XCTAssertTrue(connection.allows(URL(string: "http://192.168.1.8:8080/get/epub/1")!))
    XCTAssertFalse(connection.allows(URL(string: "https://192.168.1.8:8080/get/epub/1")!))
    XCTAssertFalse(connection.allows(URL(string: "http://other.local:8080/opds")!))
    XCTAssertThrowsError(try CalibreConnection(address: "file:///etc/passwd"))
    XCTAssertThrowsError(try CalibreConnection(address: "http://user:secret@server.local"))
  }
  func testNavigationFormatsAndSearchTemplate() throws {
    let xml = """
      <feed xmlns="http://www.w3.org/2005/Atom" xml:base="/proxy/">
        <title>我的书库</title><link rel="next" href="opds?offset=30"/>
        <link rel="search" href="opds/search/{searchTerms}?library_id=中文"/>
        <entry><id>category</id><title>按作者</title>
          <link type="application/atom+xml;profile=opds-catalog" href="opds/authors"/>
        </entry>
        <entry><id>book</id><title>书名 &amp; 副题</title><author><name>作者甲</name></author>
          <author><name>作者乙</name></author>
          <link rel="http://opds-spec.org/acquisition" type="application/pdf" href="get/pdf/1"/>
          <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="get/epub/1"/>
          <link rel="http://opds-spec.org/acquisition" type="application/octet-stream" href="get/azw3/1"/>
          <link rel="http://opds-spec.org/acquisition" type="application/x-fictionbook+xml" href="get/fb2/1"/>
        </entry>
      </feed>
      """
    let result = try CalibreCatalogParser.parse(Data(xml.utf8), at: URL(string: "http://server.local/proxy/opds")!)
    XCTAssertEqual(result.title, "我的书库")
    XCTAssertEqual(result.entries.count, 2)
    XCTAssertEqual(result.entries[0].navigationURL?.path, "/proxy/opds/authors")
    XCTAssertEqual(result.entries[1].title, "书名 & 副题")
    XCTAssertEqual(result.entries[1].authors, ["作者甲", "作者乙"])
    XCTAssertEqual(result.entries[1].downloads.map(\.format), [.pdf, .epub, .azw3])
    XCTAssertEqual(result.entries[1].preferredDownload?.format, .epub)
    XCTAssertEqual(result.nextURL?.query, "offset=30")
    let search = try result.searchURL(query: "中文 &/书")
    XCTAssertTrue(search.absoluteString.contains("%E4%B8%AD%E6%96%87%20%26%2F%E4%B9%A6"))
    XCTAssertEqual(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "中文")
  }
  func testRejectsInvalidCatalogsAndEntities() {
    let url = URL(string: "http://server.local/opds")!
    for xml in ["<html>登录页面</html>", "<feed", "<!DOCTYPE feed [<!ENTITY x 'bad'>]><feed>&x;</feed>"] {
      XCTAssertThrowsError(try CalibreCatalogParser.parse(Data(xml.utf8), at: url))
    }
  }
}

#if os(Linux) || os(macOS)
// 网络测试使用真实 HTTP 服务器；通过导入服务校验文件、分类归属和重复检测。
final class CalibreNetworkTests: XCTestCase {
  private var server: Process!
  private var base: String!
  private var scratch: URL!
  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent("CalibreTest-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    server.arguments = ["python3", Bundle.module.url(forResource: "calibre_server", withExtension: "py", subdirectory: "Fixtures")!.path]
    let pipe = Pipe()
    server.standardOutput = pipe
    try server.run()
    var line = Data()
    while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
      if byte[0] == 10 { break }
      line.append(byte)
    }
    let port = try XCTUnwrap(Int(String(decoding: line, as: UTF8.self)))
    base = "http://127.0.0.1:\(port)"
  }
  override func tearDownWithError() throws {
    if server?.isRunning == true { server.terminate(); server.waitUntilExit() }
    if let scratch { try? FileManager.default.removeItem(at: scratch) }
  }

  // Basic 走系统认证回调，搜索后下载并验证重复导入不会新增书目。
  func testAuthenticatedSearchDownloadAndImport() async throws {
    try await verifyAuthenticatedImport(kind: "basic")
  }

  // Linux Foundation 的 Digest 处理尚未实现；保留 Apple 平台测试，不把跳过写成通过。
  func testDigestAuthenticationOnApplePlatform() async throws {
    #if os(Linux)
    throw XCTSkip("swift-corelibs-foundation 尚未实现 Digest，需在 Apple 平台验收")
    #else
    try await verifyAuthenticatedImport(kind: "digest")
    #endif
  }
  private func verifyAuthenticatedImport(kind: String) async throws {
      let client = CalibreClient(connection: try CalibreConnection(address: base + "/" + kind,
        username: "reader", password: "test-pass"))
      let catalog = try await client.catalog()
      let search = try await client.catalog(at: catalog.searchURL(query: "中文"))
      let entry = try XCTUnwrap(search.entries.first)
      let download = try XCTUnwrap(entry.preferredDownload)
      let file = try await client.download(download, title: String(repeating: "中文长书名", count: 40))
      defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
      XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("离线阅读"))
      let repository = try LibraryRepository(root: scratch.appendingPathComponent(kind))
      let folder = LibraryFolder(title: "Calibre 导入")
      try await repository.saveFolder(folder)
      let importer = ImportService(repository: repository)
      let first = await importer.process(try await importer.enqueue(source: file, folderID: folder.id))
      let second = await importer.process(try await importer.enqueue(source: file, folderID: folder.id))
      XCTAssertEqual(first.state, .completed)
      XCTAssertEqual(second.state, .duplicate)
      let books = try await repository.books()
      XCTAssertEqual(books.count, 1)
      XCTAssertEqual(books[0].folderID, folder.id)
      let page2 = try await client.catalog(at: XCTUnwrap(catalog.nextURL))
      XCTAssertTrue(page2.entries.isEmpty)
  }

  // 错误密码、跨服务器跳转和超大响应均必须失败，不能把错误页当作电子书。
  func testAuthenticationRedirectAndSizeFailures() async throws {
    let wrong = CalibreClient(connection: try CalibreConnection(address: base + "/basic", username: "reader", password: "wrong"))
    do { _ = try await wrong.catalog(); XCTFail("错误密码应失败") } catch {}
    let client = CalibreClient(connection: try CalibreConnection(address: base))
    for path in ["/redirect", "/huge"] {
      do { _ = try await client.catalog(at: URL(string: base + path)); XCTFail("应拒绝此响应") } catch {}
    }
  }

  // 中途取消必须尽快返回，下载目录不应留下半本书供误导入。
  func testCancellationRemovesPartialDownload() async throws {
    let client = CalibreClient(connection: try CalibreConnection(address: base))
    let download = CalibreDownload(url: URL(string: base + "/slow/get/txt/1")!, mediaType: "text/plain")!
    let before = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
      .filter { $0.hasPrefix("Calibre-") }
    let task = Task { try await client.download(download, title: "取消样书") }
    try await Task.sleep(for: .milliseconds(120))
    task.cancel()
    do { _ = try await task.value; XCTFail("取消应中止下载") } catch is CancellationError {} catch { XCTFail("应返回取消错误：\(error)") }
    let after = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
      .filter { $0.hasPrefix("Calibre-") }
    XCTAssertEqual(Set(before), Set(after))
  }

  // 可选联调连接项目独立样书库；未提供地址时明确跳过，不冒充真实 Calibre 验证。
  func testRealCalibreServer() async throws {
    guard let address = ProcessInfo.processInfo.environment["MIOLIB_CALIBRE_TEST_URL"] else {
      throw XCTSkip("未指定真实 Calibre 测试服务器")
    }
    let client = CalibreClient(connection: try CalibreConnection(address: address))
    var catalog = try await client.catalog()
    let firstNavigation = try XCTUnwrap(catalog.entries.first { $0.navigationURL != nil })
    catalog = try await client.catalog(at: firstNavigation.navigationURL)
    let matches = try await client.catalog(at: catalog.searchURL(query: "中文样书"))
    let entry = try XCTUnwrap(matches.entries.first { $0.preferredDownload != nil })
    let file = try await client.download(XCTUnwrap(entry.preferredDownload), title: entry.title)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("第一章 初见"))
    let repository = try LibraryRepository(root: scratch.appendingPathComponent("Real"))
    let importer = ImportService(repository: repository)
    let result = await importer.process(try await importer.enqueue(source: file))
    XCTAssertEqual(result.state, .completed)
  }
}
#endif
