import BackgroundTasks
import UIKit

// 缓存队列使用系统授予的后台执行时间，到期后交还任务并通知队列保存断点。
@MainActor final class WebCacheBackgroundExecution {
  private var assertion: UIBackgroundTaskIdentifier = .invalid
  private var continuedTask: BGTask?
  private var requestID: String?
  private var expiration: (() -> Void)?
  private var generation = UUID()
  private var progress: (count: Int, total: Int?, label: String) = (0, nil, "正在准备离线正文")

  var canContinue: Bool { assertion != .invalid || continuedTask != nil }

  // UIKit 的任务保护短期退到后台的场景。iOS 26 起尝试申请系统的长任务。
  func beginIfNeeded(onExpiration: @escaping () -> Void) {
    guard expiration == nil, UIApplication.shared.applicationState != .background else { return }
    let token = UUID()
    generation = token
    expiration = onExpiration
    assertion = UIApplication.shared.beginBackgroundTask(withName: "缓存网页书籍") { [weak self] in
      self?.expire(token)
    }
    if #available(iOS 26, *) { requestContinuedProcessing(token) }
  }

  // 动态标识只注册一次，符合系统要求，也避免重签安装后的标识不匹配。
  @available(iOS 26, *)
  private func requestContinuedProcessing(_ token: UUID) {
    guard UIApplication.shared.applicationState == .active,
      let bundleID = Bundle.main.bundleIdentifier else { return }
    let prefix = bundleID + ".web-cache."
    let identifiers = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
    guard identifiers?.contains(prefix + "*") == true else { return }
    let id = prefix + UUID().uuidString
    guard BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main, launchHandler: { [weak self] task in
      Task { @MainActor in
        guard let self else { task.setTaskCompleted(success: false); return }
        self.accept(task, id: id, token: token)
      }
    }) else { return }

    // 立即分配失败时沿用短时任务，避免系统排队后为已结束的缓存重复启动任务。
    requestID = id
    let request = BGContinuedProcessingTaskRequest(identifier: id, title: "缓存网页书籍", subtitle: progress.label)
    request.strategy = .fail
    Task {
      do {
        try await Self.submit(request)
        if generation != token { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id) }
      } catch {
        if generation == token { requestID = nil }
      }
    }
  }

  // 在后台提交请求，按系统版本适配新版异步接口与 iOS 26 的接口。
  @available(iOS 26, *)
  private nonisolated static func submit(_ request: BGContinuedProcessingTaskRequest) async throws {
    if #available(iOS 27, *) { try await BGTaskScheduler.shared.submitTaskRequest(request) }
    else { try BGTaskScheduler.shared.submit(request) }
  }

  // 系统接管执行时间后释放短时任务。过期回调只影响当前这一批缓存。
  @available(iOS 26, *)
  private func accept(_ task: BGTask, id: String, token: UUID) {
    guard requestID == id, generation == token, let task = task as? BGContinuedProcessingTask else {
      task.setTaskCompleted(success: false)
      return
    }
    continuedTask = task
    task.expirationHandler = { [weak self] in
      Task { @MainActor in self?.expire(token) }
    }
    report(count: progress.count, total: progress.total, label: progress.label)
    endAssertion()
  }

  // 系统进度与已落盘的章节数同步，合并 EPUB 完成前保留最后一个单位。
  func report(count: Int, total: Int?, label: String) {
    progress = (count, total, label)
    if #available(iOS 26, *), let task = continuedTask as? BGContinuedProcessingTask {
      task.progress.totalUnitCount = Int64(max(count + 1, (total ?? 0) + 1))
      task.progress.completedUnitCount = Int64(count)
      if task.subtitle != label { task.updateTitle("缓存网页书籍", subtitle: label) }
    }
  }

  // 成功、用户暂停和系统到期都会清理任务，迟到的系统回调不会重新启动已结束的任务。
  func finish(success: Bool) {
    generation = UUID()
    expiration = nil
    if let requestID { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestID) }
    requestID = nil
    if let task = continuedTask {
      task.expirationHandler = nil
      if #available(iOS 26, *), success, let task = task as? BGContinuedProcessingTask {
        task.progress.completedUnitCount = task.progress.totalUnitCount
      }
      task.setTaskCompleted(success: success)
    }
    continuedTask = nil
    endAssertion()
  }

  // 不等待网络或数据库清理，先向系统归还已经过期的执行时间。
  private func expire(_ token: UUID) {
    guard generation == token, let expiration else { return }
    finish(success: false)
    expiration()
  }

  // 只结束本实例持有的 UIKit 任务，重复调用时没有副作用。
  private func endAssertion() {
    guard assertion != .invalid else { return }
    UIApplication.shared.endBackgroundTask(assertion)
    assertion = .invalid
  }
}
