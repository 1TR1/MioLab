// 缓存重试只依据已经落盘的章节、失败次数和单调时钟，等待队列不计入开始时间。
public struct WebCacheRetry: Sendable {
  public static let failureWindow: Duration = .seconds(30)
  private var failures = 0
  private var downloadedAtLastFailure = 0

  public init() {}

  // 有新的章节落盘时恢复短间隔，持续失败才逐步放慢请求。
  public mutating func recordFailure(downloaded: Int) {
    if downloaded > downloadedAtLastFailure { failures = 0 }
    downloadedAtLastFailure = downloaded
    failures = min(failures + 1, 7)
  }

  // 有章节可读时继续后台重试；无正文的书同时满足三项条件才提示失败。
  public func shouldReportFailure(elapsed: Duration, downloaded: Int) -> Bool {
    failures >= 2 && downloaded == 0 && elapsed >= Self.failureWindow
  }

  // 在 30 秒截止点重新评估空缓存，避免退避把应出现的提示延后很久。
  public func delay(elapsed: Duration, downloaded: Int) -> Duration {
    let backoff = Duration.seconds(min(60, 1 << max(0, failures - 1)))
    if failures >= 2 && downloaded == 0 {
      return min(backoff, max(.zero, Self.failureWindow - elapsed))
    }
    return backoff
  }
}
