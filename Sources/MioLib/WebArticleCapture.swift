import ImageIO
import MioLibCore
import WebKit

// 使用当前 WebKit 文档提取已加载正文，登录和动态渲染仍由原来的浏览器处理。
@MainActor enum WebArticleCapture {
  static func article(from webView: WKWebView) async throws -> WebArticle {
    guard let readabilityURL = Bundle.module.url(forResource: "Readability", withExtension: "js"),
      let extractorURL = Bundle.module.url(forResource: "WebArticleExtractor", withExtension: "js"),
      let navigationURL = Bundle.module.url(forResource: "WebChapterNavigation", withExtension: "js") else {
      throw LibraryError.message("缺少正文提取组件，请重新安装应用")
    }
    let script = try String(contentsOf: navigationURL, encoding: .utf8) + "\n"
      + String(contentsOf: readabilityURL, encoding: .utf8) + "\n"
      + String(contentsOf: extractorURL, encoding: .utf8)
    let result = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
    try Task.checkCancellation()
    guard let json = result as? String, let data = json.data(using: .utf8), data.count <= 8 * 1024 * 1024 else {
      throw LibraryError.message("网页没有返回有效正文，请使用原网页阅读")
    }
    return try LibraryJSON.decode(WebArticle.self, from: data)
  }

  // 导航独立提取，旧版缓存只需补齐元数据，不重新生成已经标注过的正文。
  static func navigation(from webView: WKWebView) async throws -> WebChapterNavigation {
    guard let url = Bundle.module.url(forResource: "WebChapterNavigation", withExtension: "js") else {
      throw LibraryError.message("缺少章节导航组件")
    }
    let script = try String(contentsOf: url, encoding: .utf8) + "\nreturn JSON.stringify(mioLibChapterNavigation(true));"
    let result = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
    try Task.checkCancellation()
    guard let json = result as? String, let data = json.data(using: .utf8) else { throw LibraryError.message("网页未返回章节导航") }
    return try LibraryJSON.decode(WebChapterNavigation.self, from: data)
  }

  // 仅保存最多 20 张公开图片；不复制登录 Cookie，图片不可下载时保留正文和替代文字。
  nonisolated static func images(for article: WebArticle) async throws -> [WebArticleImage] {
    var seen: Set<URL> = []
    let urls = article.blocks.compactMap { $0.kind == .image ? $0.url : nil }
      .filter { seen.insert($0).inserted }.prefix(20)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 8
    configuration.timeoutIntervalForResource = 15
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var images: [WebArticleImage] = []
    var total = 0
    // 每批最多并发三张，避免长文章同时打开大量网络连接或解码过多图片。
    let candidates = Array(urls)
    for start in stride(from: 0, to: candidates.count, by: 3) {
      try Task.checkCancellation()
      let batch = candidates[start..<min(start + 3, candidates.count)]
      let downloaded = await withTaskGroup(of: WebArticleImage?.self, returning: [WebArticleImage].self) { group in
        for url in batch { group.addTask { try? await image(at: url, session: session) } }
        var results: [WebArticleImage] = []
        for await result in group { if let result { results.append(result) } }
        return results
      }
      for image in downloaded where total + image.data.count <= 24 * 1024 * 1024 {
        images.append(image)
        total += image.data.count
      }
    }
    try Task.checkCancellation()
    return images
  }

  // 读取响应时限制字节数，再用 ImageIO 缩略并重编码，避免嵌入活动内容或巨幅图片。
  nonisolated private static func image(at url: URL, session: URLSession) async throws -> WebArticleImage {
    let target = try WebAddress.url(url.absoluteString)
    let (bytes, response) = try await session.bytes(from: target)
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
      response.mimeType?.hasPrefix("image/") == true,
      response.expectedContentLength <= 6 * 1024 * 1024 else { throw LibraryError.message("正文图片不可用") }
    var data = Data()
    for try await byte in bytes {
      if data.count % 16384 == 0 { try Task.checkCancellation() }
      guard data.count < 6 * 1024 * 1024 else { throw LibraryError.message("正文图片过大") }
      data.append(byte)
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 1600,
        kCGImageSourceCreateThumbnailWithTransform: true,
      ] as CFDictionary) else { throw LibraryError.message("无法解码正文图片") }
    let result = NSMutableData()
    guard let writer = CGImageDestinationCreateWithData(result, "public.jpeg" as CFString, 1, nil) else {
      throw LibraryError.message("无法保存正文图片")
    }
    CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
    guard CGImageDestinationFinalize(writer) else { throw LibraryError.message("正文图片保存失败") }
    return WebArticleImage(url: target, data: result as Data)
  }
}
