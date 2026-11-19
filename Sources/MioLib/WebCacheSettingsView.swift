import MioLibCore
import SwiftUI

// 缓存设置只列书架中的网页书，从这里选卷或清理离线正文。
struct WebCacheSettingsView: View {
  @ObservedObject var model: AppModel
  private var books: [Book] { model.books.filter { $0.format == .web } }

  var body: some View {
    List {
      ForEach(books) { book in
        NavigationLink { WebVolumeSettingsView(model: model, bookID: book.id) } label: {
          VStack(alignment: .leading, spacing: 5) {
            Text(book.title).foregroundStyle(.primary)
            let count = book.downloadedWebChapters.count
            Text(count == 0 ? "无离线缓存" : "已缓存 \(count) 章")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      if books.isEmpty {
        ContentUnavailableView("没有网页书籍", systemImage: "books.vertical",
          description: Text("把已收藏的网址导出至书架后，即可管理离线缓存。"))
      }
    }.navigationTitle("网页书籍缓存")
  }
}

// 同一套卷设置可从“我的”进入，也可在尚无缓存的网页书阅读入口直接打开。
struct WebVolumeSettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var cache: WebBookCache
  let bookID: UUID
  @State private var loading = false
  @State private var changing = false
  @State private var directoryError = false
  @State private var error: String?
  @State private var deleting: WebBookVolume?

  init(model: AppModel, bookID: UUID) {
    self.model = model
    self.bookID = bookID
    _cache = ObservedObject(wrappedValue: model.webBookCache)
  }

  private var book: Book? { model.books.first { $0.id == bookID && $0.format == .web } }

  // 旧书联网补齐目录后显示分卷。暂时没有目录时仍能清理整本的离线数据。
  var body: some View {
    List {
      if let book {
        if loading {
          Section { ProgressView("正在读取卷目录…") }
        } else {
          if directoryError {
            Section {
              Text("暂时无法读取卷目录。").foregroundStyle(.secondary)
              Button("重试读取目录") { Task { await loadDirectory() } }
            }
          }
          Section {
            ForEach(book.webCacheVolumes) { volume in volumeRow(volume, book: book) }
          } header: { Text("离线缓存") } footer: {
            Text("删除会清理该卷的离线正文并结束该卷的下载。书目、笔记和书签会保留。")
          }
          if book.hasWebCacheSelection { queueSection(book) }
        }
      } else {
        ContentUnavailableView("书籍已移除", systemImage: "book.closed")
      }
    }
    .navigationTitle(book?.title ?? "网页书籍缓存").navigationBarTitleDisplayMode(.inline)
    .disabled(changing || model.maintenance)
    .task(id: book?.originalPath) { await loadDirectory() }
    .alert("缓存设置", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("好", role: .cancel) { error = nil }
    } message: { Text(error ?? "") }
    .confirmationDialog("删除所选卷的离线缓存？",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible
    ) {
      if let deleting { Button("删除缓存", role: .destructive) { change(deleting, enabled: false) } }
      Button("取消", role: .cancel) { deleting = nil }
    } message: { Text(deleting?.title ?? "") }
  }

  // 已下载、待下载和未选择三种卷都有各自的操作入口。
  private func volumeRow(_ volume: WebBookVolume, book: Book) -> some View {
    let count = max(book.downloadedWebChapters(in: volume).count, cache.statuses[bookID]?.count(in: volume) ?? 0)
    let selected = book.wantsWebVolume(volume)
    let total = volume.chapterURLs.count
    return HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(volume.title)
        if total > 0 {
          Text(count > 0 ? "已缓存 \(count) / \(total) 章" : "\(total) 章 · \(selected ? "待缓存" : "未缓存")")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          Text(count > 0 ? "已缓存 \(count) 章" : (selected ? "待缓存" : "未缓存"))
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 4)
      if count > 0 {
        Button("删除", role: .destructive) { deleting = volume }
          .buttonStyle(.borderless).accessibilityLabel("删除\(volume.title)缓存")
      } else if selected {
        Button("取消缓存") { change(volume, enabled: false) }
          .buttonStyle(.borderless).accessibilityLabel("取消缓存\(volume.title)")
      } else {
        Button("缓存") { change(volume, enabled: true) }
          .buttonStyle(.borderless).accessibilityLabel("缓存\(volume.title)")
      }
    }
  }

  // 状态跟随后台队列；用户也可开始或暂停此前选择的卷。
  private func queueSection(_ book: Book) -> some View {
    Section {
      if let status = cache.statuses[bookID] { Text(status.label).font(.footnote).foregroundStyle(.secondary) }
      switch cache.statuses[bookID]?.phase {
      case .queued, .downloading, .retrying:
        Button("暂停缓存") { cache.pause(bookID) }
      default:
        if book.webCacheCompleted != true { Button("下载所选卷") { cache.start(book) } }
      }
    }
  }

  // 获取目录只写入同一个来源的书，避免在改链接后保存过时的结果。
  private func loadDirectory() async {
    directoryError = false
    guard !loading, let book, book.webVolumes == nil, let source = book.webURL,
      WebReaderNavigation.hasVolumeDirectory(at: source), let repository = model.repository else { return }
    loading = true
    defer { loading = false }
    do {
      let volumes = try await WebReaderNavigation(model: model).loadVolumes(at: source)
      try Task.checkCancellation()
      _ = try await repository.recordWebVolumes(volumes, for: book)
      try await model.reload()
    } catch is CancellationError {} catch { directoryError = true }
  }

  // 先停稳当前书的下载，再提交用户选择。失败后从原选择续跑。
  private func change(_ volume: WebBookVolume, enabled: Bool) {
    guard let book, let repository = model.repository, !changing else { return }
    deleting = nil
    changing = true
    Task {
      let wasDownloading = await cache.pauseAndWait(bookID)
      defer { changing = false }
      do {
        let updated = try await repository.setWebVolumeCached(enabled, volumeID: volume.id, for: book)
        cache.volumeSelectionChanged(updated, resume: enabled || wasDownloading)
        try await model.reload()
      } catch {
        if wasDownloading, let current = try? await repository.book(bookID) { cache.start(current) }
        self.error = error.localizedDescription
      }
    }
  }
}
