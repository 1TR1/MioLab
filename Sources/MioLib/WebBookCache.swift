import MioLibCore
import SwiftUI

// 缓存队列独立于书架和阅读窗口，由 App 生命周期管理后台执行时间。
@MainActor final class WebBookCache: ObservableObject {
  enum Phase: Equatable { case queued, downloading, retrying, systemPaused, complete, paused, failed(String) }

  // 只公布章数与可读副本路径，下载每章无需刷新整套书架和标注。
  struct Status: Equatable {
    var phase: Phase
    var count: Int
    var total: Int?
    // 进度分母只覆盖本次选中的卷。旧卷仍计入书库的已缓存章数。
    var selectedCount: Int
    var readingPath: String?
    // 设置页从队列显示已经落盘的章数，处理完成前也能准确选择要删除的卷。
    var downloadedKeys: Set<String>
    func count(in volume: WebBookVolume) -> Int {
      volume == .wholeBook ? count : volume.chapterURLs.filter { downloadedKeys.contains(WebChapterAddress.identity($0)) }.count
    }
    var label: String {
      switch phase {
      case .queued: return "等待缓存"
      case .downloading:
        if let total { return selectedCount >= total ? "正在整理离线正文…" : "正在缓存 \(selectedCount) / \(total) 章" }
        return count > 0 ? "正在缓存 · 已下载 \(count) 章" : "正在准备离线正文…"
      case .retrying: return count > 0 ? "已缓存 \(count) 章 · 等待重试" : "正在自动重试…"
      case .systemPaused: return "等待系统恢复缓存 · 已下载 \(count) 章"
      case .complete: return "已离线缓存 \(count) 章"
      case .paused: return "缓存已暂停 · 已下载 \(count) 章"
      case .failed(let reason): return "缓存失败：\(reason)"
      }
    }
  }

  // 一个书目保留下载断点与退避状态，正在等待重试时其他书可以先下载。
  private final class Job {
    var book: Book
    var directory: [URL] = []
    var retry = WebCacheRetry()
    var startedAt: ContinuousClock.Instant?
    var retryAt: ContinuousClock.Instant?
    var lastFailure: String?
    var failureDeadline: Task<Void, Never>?
    init(_ book: Book) {
      self.book = book
      // 已知目录时，初始的重试判断也只检查本次选择。
      directory = book.webVolumes?.filter(book.wantsWebVolume).flatMap(\.chapterURLs) ?? []
    }
  }

  @Published private(set) var statuses: [UUID: Status] = [:]
  private weak var model: AppModel?
  private let clock = ContinuousClock()
  private let runtime = WebCacheBackgroundExecution()
  private var active: Job?
  private var task: Task<Void, Never>?
  private var retryWake: Task<Void, Never>?
  private var queue: [Job] = []
  private var scene: ScenePhase = .active
  private var suspended = false
  private var batchSucceeded = true

  init(model: AppModel) { self.model = model }

  // 明确确认下载或继续后才入队。同一书目重复提交时复用正在进行的任务。
  func start(_ book: Book, prioritize: Bool = false) {
    guard book.format == .web, book.webURL != nil, let model, !model.maintenance else { return }
    guard book.hasWebCacheSelection else { statuses[book.id] = nil; return }
    if book.webCacheCompleted == true {
      update(book, phase: .complete)
      return
    }
    if scene == .active { suspended = false }
    if let active, active.book.id == book.id, active.book.originalPath == book.originalPath, task?.isCancelled == false { return }
    let existing = queue.first { $0.book.id == book.id && $0.book.originalPath == book.originalPath }
    if existing != nil, !prioritize, statuses[book.id]?.phase != .systemPaused {
      // 已经排队或正在退避时，重复点击继续不会累积任务或重新计时。
      startNext()
      return
    }
    if active?.book.id == book.id { pause(book.id) }
    // 同 ID 的旧链接队列退出时，也取消其仍在等待的错误提示。
    for old in queue where old.book.id == book.id && old !== existing { cancelFailureDeadline(old) }
    queue.removeAll { $0.book.id == book.id }
    let job = existing ?? Job(book)
    job.retryAt = nil
    if prioritize {
      // 用户要读另一本尚无正文的书时，让它先取得首章。原任务留在队列中继续。
      if let interrupted = active, interrupted.book.id != book.id, task?.isCancelled == false {
        task?.cancel()
        queue.append(interrupted)
        update(interrupted.book, phase: .queued, directory: interrupted.directory)
      }
      queue.insert(job, at: 0)
    } else { queue.append(job) }
    update(job.book, phase: .queued, directory: job.directory)
    startNext()
  }

  // 同时只运行一个站点会话。等待退避时设置一次唤醒，其他已就绪的书仍可启动。
  private func startNext() {
    guard task == nil else { return }
    retryWake?.cancel()
    retryWake = nil
    guard !queue.isEmpty else { runtime.finish(success: batchSucceeded); return }
    guard !suspended else { return }
    if scene != .background && !runtime.canContinue {
      batchSucceeded = true
      runtime.beginIfNeeded { [weak self] in self?.suspendForSystem() }
    }
    if scene == .background && !runtime.canContinue { suspendForSystem(); return }

    let now = clock.now
    guard let index = queue.firstIndex(where: { $0.retryAt.map { $0 <= now } ?? true }) else {
      if let next = queue.compactMap(\.retryAt).min() {
        retryWake = Task { [weak self, clock] in
          do { try await clock.sleep(until: next) } catch { return }
          self?.startNext()
        }
      }
      return
    }
    let job = queue.remove(at: index)
    active = job
    if job.startedAt == nil { job.startedAt = now }
    update(job.book, phase: .downloading, directory: job.directory)
    task = Task { [weak self] in
      guard let self else { return }
      defer {
        self.task = nil
        self.active = nil
        self.startNext()
      }
      guard !Task.isCancelled else { return }
      await self.download(job)
    }
  }

  // 暂停只停止网络与组包。已经保存的章节会在继续或下次打开时复用。
  func pause(_ bookID: UUID) {
    if let active, active.book.id == bookID {
      cancelFailureDeadline(active)
      task?.cancel()
    }
    for job in queue where job.book.id == bookID { cancelFailureDeadline(job) }
    queue.removeAll { $0.book.id == bookID }
    statuses[bookID]?.phase = .paused
    batchSucceeded = false
    startNext()
  }

  // 改动卷选择或手动切章前等待旧任务退出，避免并行写入同一阅读副本。
  func pauseAndWait(_ bookID: UUID) async -> Bool {
    let queued = queue.contains { $0.book.id == bookID }
    let running = active?.book.id == bookID ? task : nil
    let resume = queued || running?.isCancelled == false
    guard queued || running != nil else { return false }
    pause(bookID)
    await running?.value
    return resume
  }

  // 删除卷后以数据库中的路径和章数更新界面，避免显示已移除的旧副本。
  func volumeSelectionChanged(_ book: Book, resume: Bool) {
    if !book.hasWebCacheSelection { statuses[book.id] = nil }
    else if resume { start(book) }
    else { update(book, phase: book.webCacheCompleted == true ? .complete : .paused) }
  }

  // 退到后台继续使用已获批的执行时间，回前台自动恢复因系统暂停的队列。
  func sceneChanged(_ phase: ScenePhase) {
    scene = phase
    if phase == .active {
      suspended = false
      for job in queue { scheduleFailureDeadline(job) }
      startNext()
    } else if phase == .background, (task != nil || !queue.isEmpty), !runtime.canContinue {
      suspendForSystem()
    }
  }

  // 系统停止任务时保留队列和已经提交的正文。用户手动暂停的任务不会被加回。
  private func suspendForSystem() {
    suspended = true
    runtime.finish(success: false)
    retryWake?.cancel()
    retryWake = nil
    if let active, task?.isCancelled == false {
      queue.insert(active, at: 0)
      task?.cancel()
    }
    for job in queue {
      cancelFailureDeadline(job)
      update(job.book, phase: .systemPaused, directory: job.directory)
    }
  }

  // 一次尝试开始和失败后都重新核对数据库，改链、删除、恢复的旧任务直接退出。
  private func download(_ job: Job) async {
    guard let model, let repository = model.repository else { return }
    guard let current = try? await repository.book(job.book.id), !Task.isCancelled,
      current.deletedAt == nil, current.originalPath == job.book.originalPath else {
      if !Task.isCancelled { cancelFailureDeadline(job) }
      return
    }
    job.book = current
    if model.maintenance || !current.hasWebCacheSelection {
      cancelFailureDeadline(job)
      update(current, phase: .paused, directory: job.directory)
      return
    }

    // 等待超过 30 秒且已有多次实际失败时，先复核是否有新正文到达，再决定提示。
    if let failure = job.lastFailure, reportFailureIfDue(job, reason: failure) { return }
    do {
      let navigator = WebReaderNavigation(model: model)
      job.book = try await navigator.cacheBook(current) { book, orderedURLs in
        job.book = book
        if !orderedURLs.isEmpty { job.directory = orderedURLs }
        if !Task.isCancelled {
          if self.count(for: job) > 0 { self.cancelFailureDeadline(job) }
          self.update(book, phase: .downloading, directory: job.directory)
        }
      }
      guard !Task.isCancelled else { return }
      try? await model.reload()
      if !Task.isCancelled {
        cancelFailureDeadline(job)
        update(job.book, phase: job.book.webCacheCompleted == true ? .complete : .paused, directory: job.directory)
      }
    } catch {
      await handleFailure(error, in: job, model: model, repository: repository)
    }
  }

  // 先保留已下载页面，再把失败项带着退避时间放回队列。
  private func handleFailure(_ error: Error, in job: Job, model: AppModel, repository: LibraryRepository) async {
    guard !Task.isCancelled, let latest = try? await repository.book(job.book.id),
      !Task.isCancelled, latest.deletedAt == nil, latest.originalPath == job.book.originalPath else { return }
    job.book = latest
    if latest.webPendingChapters != nil,
      let partial = try? await repository.publishWebChapters(for: latest, directory: job.directory) {
      job.book = partial
      try? await model.reload()
    }
    guard !Task.isCancelled else { return }
    let reason = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
    let downloaded = count(for: job)
    job.retry.recordFailure(downloaded: downloaded)
    job.lastFailure = reason
    if reportFailureIfDue(job, reason: reason) { return }
    job.retryAt = clock.now.advanced(by: job.retry.delay(elapsed: elapsed(for: job), downloaded: downloaded))
    queue.append(job)
    update(job.book, phase: .retrying, directory: job.directory)
    scheduleFailureDeadline(job)
  }

  // 空缓存反复失败后单独观察截止时间，即使队列正在处理另一本书也能及时提示。
  private func scheduleFailureDeadline(_ job: Job) {
    guard job.failureDeadline == nil, let startedAt = job.startedAt,
      job.retry.shouldReportFailure(elapsed: WebCacheRetry.failureWindow, downloaded: count(for: job)) else { return }
    let deadline = startedAt.advanced(by: WebCacheRetry.failureWindow)
    job.failureDeadline = Task { [weak self, weak job, clock] in
      do { try await clock.sleep(until: deadline) } catch { return }
      guard let self, let job else { return }
      await self.checkFailureDeadline(job)
    }
  }

  // 正文可能恰好落盘，截止时再从书库确认，随后结束这一轮空下载的重试。
  private func checkFailureDeadline(_ job: Job) async {
    guard !suspended, let repository = model?.repository, let reason = job.lastFailure,
      let current = try? await repository.book(job.book.id), !Task.isCancelled,
      current.deletedAt == nil, current.originalPath == job.book.originalPath,
      active === job || queue.contains(where: { $0 === job }) else { return }
    job.book = current
    if reportFailureIfDue(job, reason: reason) {
      if active === job { task?.cancel() }
      queue.removeAll { $0 === job }
      startNext()
    }
  }

  // 手动暂停、系统暂停或获得第一个章时移除尚未触发的提示。
  private func cancelFailureDeadline(_ job: Job) {
    job.failureDeadline?.cancel()
    job.failureDeadline = nil
  }

  // 满足失败次数、30 秒和零章节三项条件才报错。退出到书架也能看见当前书的失败提示。
  private func reportFailureIfDue(_ job: Job, reason: String) -> Bool {
    guard job.retry.shouldReportFailure(elapsed: elapsed(for: job), downloaded: count(for: job)) else { return false }
    cancelFailureDeadline(job)
    let detail = "已重试多次，30 秒内未下载到章节。\(reason)"
    batchSucceeded = false
    update(job.book, phase: .failed(detail), directory: job.directory)
    if let model, model.readerBook == nil, model.message == nil {
      model.message = "“\(job.book.title)”缓存失败。\(detail)"
    }
    return true
  }

  // 目录页与未选卷都不计入本次下载。保留其他卷时，新任务零下载仍可按时报告失败。
  private func count(for job: Job) -> Int {
    let chapters = job.book.downloadedWebChapters.filter { $0.navigation?.isContents != true }
    return job.directory.isEmpty ? chapters.count : count(in: job.directory, matching: chapterKeys(chapters))
  }
  private func chapterKeys(_ chapters: [WebBookChapter]) -> Set<String> {
    Set(chapters.map { WebChapterAddress.identity($0.url) })
  }
  private func count(in directory: [URL], matching keys: Set<String>) -> Int {
    directory.filter { keys.contains(WebChapterAddress.identity($0)) }.count
  }
  private func elapsed(for job: Job) -> Duration { job.startedAt?.duration(to: clock.now) ?? .zero }

  // 合并后的路径可供等待首章的阅读入口立即使用。
  private func update(_ book: Book, phase: Phase, directory: [URL] = []) {
    let chapters = book.downloadedWebChapters.filter { $0.navigation?.isContents != true }
    let keys = chapterKeys(chapters)
    let progress = directory.isEmpty ? chapters.count : count(in: directory, matching: keys)
    let status = Status(phase: phase, count: chapters.count, total: directory.isEmpty ? nil : directory.count,
      selectedCount: progress, readingPath: book.hasWebReadingCopy ? book.readingPath : nil, downloadedKeys: keys)
    statuses[book.id] = status
    if active?.book.id == book.id { runtime.report(count: progress, total: status.total, label: status.label) }
  }
}
