import XCTest
@testable import MioLibCore

// 用明确的时间值验证边界，无需等待 30 秒或访问外部站点。
final class WebCacheRetryTests: XCTestCase {
  // 零下载时需要至少两次失败，还必须经过完整的 30 秒。
  func testReportsOnlyAfterRepeatedFailuresAndThirtySeconds() {
    var retry = WebCacheRetry()
    retry.recordFailure(downloaded: 0)
    XCTAssertFalse(retry.shouldReportFailure(elapsed: .seconds(90), downloaded: 0))
    retry.recordFailure(downloaded: 0)
    XCTAssertFalse(retry.shouldReportFailure(elapsed: .milliseconds(29_999), downloaded: 0))
    XCTAssertEqual(retry.delay(elapsed: .seconds(29), downloaded: 0), .seconds(1))
    XCTAssertTrue(retry.shouldReportFailure(elapsed: .seconds(30), downloaded: 0))
  }

  // 已下载正文时持续退避重试。新下载成功后缩短退避，既有正文永远不触发零下载错误。
  func testPartialDownloadRetriesAndNewProgressResetsBackoff() {
    var retry = WebCacheRetry()
    for _ in 0..<10 { retry.recordFailure(downloaded: 1) }
    XCTAssertFalse(retry.shouldReportFailure(elapsed: .seconds(90), downloaded: 1))
    XCTAssertEqual(retry.delay(elapsed: .seconds(90), downloaded: 1), .seconds(60))
    retry.recordFailure(downloaded: 2)
    XCTAssertEqual(retry.delay(elapsed: .seconds(91), downloaded: 2), .seconds(1))
  }
}
