import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// 每次请求使用短生命周期会话，下载逐块写磁盘；连续导入时不把整本书放进内存。
public struct CalibreClient: Sendable {
  public let connection: CalibreConnection
  public init(connection: CalibreConnection) { self.connection = connection }
  public func catalog(at url: URL? = nil) async throws -> CalibreCatalog {
    let address = url ?? connection.catalogURL
    let transfer = CalibreTransfer(connection: connection, destination: nil, limit: 8 * 1024 * 1024)
    let data = try await transfer.run(url: address)
    return try CalibreCatalogParser.parse(data, at: address)
  }

  // 临时文件只在完整响应成功后交给导入服务；失败和取消都会清除残留的下载目录。
  public func download(_ item: CalibreDownload, title: String,
    progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Calibre-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // 文件系统按 UTF-8 字节限制文件名长度，避免很长的中文书名超过单文件名上限。
    var safe = ""
    for scalar in title.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
      let part = "/\\:".unicodeScalars.contains(scalar) ? "_" : String(scalar)
      if safe.utf8.count + part.utf8.count > 180 { break }
      safe += part
    }
    let destination = directory.appendingPathComponent(safe.isEmpty ? "Calibre 书籍" : safe)
      .appendingPathExtension(item.format.rawValue)
    do {
      let transfer = CalibreTransfer(connection: connection, destination: destination,
        limit: 512 * 1024 * 1024, progress: progress)
      _ = try await transfer.run(url: item.url)
      return destination
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }
}

// 委托在独立串行队列上处理响应；锁仅保护取消与任务创建之间的竞态。
private final class CalibreTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let connection: CalibreConnection
  private let destination: URL?
  private let limit: Int
  private let progress: @Sendable (Double) -> Void
  private let lock = NSLock()
  private var task: URLSessionDataTask?
  private var cancelled = false
  private var continuation: CheckedContinuation<Data, Error>?
  private var file: FileHandle?
  private var data = Data()
  private var received = 0
  private var expected: Int64 = -1
  private var acceptingBody = false
  private var lastStatus = 0
  private var failure: Error?
  private var lastProgress = Date.distantPast
  init(connection: CalibreConnection, destination: URL?, limit: Int,
    progress: @escaping @Sendable (Double) -> Void = { _ in })
  {
    self.connection = connection
    self.destination = destination
    self.limit = limit
    self.progress = progress
  }

  // 取消在创建任务之前发生时也会被记住，避免关闭界面后仍留下后台传输。
  func run(url: URL) async throws -> Data {
    guard connection.allows(url) else { throw LibraryError.message("书库链接指向其他服务器，已停止连接") }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        if cancelled {
          lock.unlock()
          continuation.resume(throwing: CancellationError())
          return
        }
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        var request = URLRequest(url: url)
        request.setValue(destination == nil ? "application/atom+xml" : "application/octet-stream", forHTTPHeaderField: "Accept")
        let next = session.dataTask(with: request)
        task = next
        lock.unlock()
        next.resume()
      }
    } onCancel: {
      self.lock.lock()
      self.cancelled = true
      let task = self.task
      self.lock.unlock()
      task?.cancel()
    }
  }

  // Basic / Digest 由系统处理挑战；凭据不写 URL，不忽略 HTTPS 证书校验。
  func urlSession(_ session: URLSession, task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
  {
    let space = challenge.protectionSpace
    if [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest].contains(space.authenticationMethod) {
      guard challenge.previousFailureCount == 0, !connection.username.isEmpty,
        space.host.lowercased() == connection.catalogURL.host?.lowercased(),
        task.currentRequest?.url.map(connection.allows) == true
      else {
        failure = LibraryError.message("Calibre 登录失败，请检查用户名和密码")
        completionHandler(.cancelAuthenticationChallenge, nil)
        return
      }
      completionHandler(.useCredential, URLCredential(user: connection.username,
        password: connection.password, persistence: .forSession))
    } else { completionHandler(.performDefaultHandling, nil) }
  }

  // 拒绝跨服务器重定向，避免代理配置错误时把身份信息带到另一台主机。
  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void)
  {
    guard let url = request.url, connection.allows(url) else {
      failure = LibraryError.message("服务器将请求重定向至其他地址，请填写最终的 Calibre 地址")
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }

  // 在响应头和逐块写入处各做一次大小校验，兼容没有 Content-Length 的服务器。
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void)
  {
    lastStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
    // Linux Foundation 先回调 401 再发认证挑战；忽略挑战正文，交由系统完成认证重试。
    if lastStatus == 401, !connection.username.isEmpty {
      acceptingBody = false
      completionHandler(.allow)
      return
    }
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      failure = LibraryError.message(status == 401 || status == 403
        ? "Calibre 登录失败，请检查用户名、密码和书库访问权限"
        : status == 404 ? "未找到书库或书籍；搜索时也可能表示没有匹配结果（HTTP 404）"
        : "Calibre 服务器返回 HTTP \(status)")
      completionHandler(.cancel)
      return
    }
    expected = response.expectedContentLength
    guard expected <= Int64(limit) else {
      failure = LibraryError.message("服务器文件超过允许大小（\(limit / 1024 / 1024) MB）")
      completionHandler(.cancel)
      return
    }
    do {
      if let destination {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
          throw LibraryError.message("无法创建书籍下载文件")
        }
        file = try FileHandle(forWritingTo: destination)
      }
      acceptingBody = true
      completionHandler(.allow)
    } catch { failure = error; completionHandler(.cancel) }
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
    guard failure == nil, acceptingBody else { return }
    received += chunk.count
    guard received <= limit else {
      failure = LibraryError.message("服务器文件超过允许大小")
      dataTask.cancel()
      return
    }
    do {
      if let file { try file.write(contentsOf: chunk) } else { data.append(chunk) }
      if Date().timeIntervalSince(lastProgress) >= 0.1 {
        lastProgress = Date()
        progress(expected > 0 ? min(1, Double(received) / Double(expected)) : 0)
      }
    } catch { failure = error; dataTask.cancel() }
  }

  // 仅在磁盘关闭成功后返回；会话结束释放委托，所有完成路径只恢复一次 continuation。
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    do { try file?.close() } catch { if failure == nil { failure = error } }
    file = nil
    session.finishTasksAndInvalidate()
    guard let result = continuation else { return }
    continuation = nil
    lock.lock()
    let wasCancelled = cancelled
    self.task = nil
    lock.unlock()
    if wasCancelled { result.resume(throwing: CancellationError()) }
    else if let failure = failure ?? error { result.resume(throwing: failure) }
    else if lastStatus == 401 { result.resume(throwing: LibraryError.message("Calibre 登录失败，请检查用户名和密码")) }
    else if received == 0 { result.resume(throwing: LibraryError.message("服务器返回空文件")) }
    else { progress(1); result.resume(returning: data) }
  }
}
