import MioLibCore
import SwiftUI

// 打开网页书时显示卷目录和已缓存状态。面板关闭前，只有确认按钮提交下载选择。
struct WebCacheSelectionView: View {
  @ObservedObject var model: AppModel
  let book: Book
  let onConfirm: (Book) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var catalog: [WebBookVolume]?
  @State private var selection: Set<String> = []
  @State private var request = UUID()
  @State private var directoryUnavailable = false
  @State private var confirming = false
  @State private var error: String?

  // 已取到的目录沿用数据库里的卷分组逻辑。目录暂时打不开时可明确选择缓存全书。
  private var volumes: [WebBookVolume] {
    var current = book
    current.webVolumes = book.webVolumes ?? catalog
    return current.webVolumes != nil || directoryUnavailable ? current.webCacheVolumes : []
  }

  var body: some View {
    let published = Set(book.cachedWebChapters.map { WebChapterAddress.identity($0.url) })
    let available = Set(volumes.filter { !isCached($0, published: published) }.map(\.id))
    return NavigationStack {
      List {
        Section(book.title) {
          if directoryUnavailable {
            Text("暂时无法读取卷目录").foregroundStyle(.secondary)
            Button("重试读取目录") { request = UUID() }
          }
          if volumes.isEmpty { ProgressView("正在读取卷目录…") }
          if available.count > 1 {
            Button(selection == available ? "取消全选" : "全选未缓存卷") {
              selection = selection == available ? [] : available
            }
          }
          ForEach(volumes) { volume in volumeRow(volume, cached: !available.contains(volume.id)) }
        }
        if let error { Section { Text(error).foregroundStyle(.red) } }
      }
      .disabled(confirming)
      .navigationTitle("选择缓存卷").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("暂不缓存") { dismiss() }.disabled(confirming) }
        ToolbarItem(placement: .confirmationAction) {
          Button("缓存所选卷") { confirm() }.disabled(selection.isEmpty || confirming || model.maintenance)
        }
      }
    }
    .interactiveDismissDisabled(confirming)
    .task(id: request) { await loadCatalog() }
  }

  // 只有已经并入可读副本的完整卷才显示“已缓存”。中断的下载仍可在这里重新勾选。
  private func isCached(_ volume: WebBookVolume, published: Set<String>) -> Bool {
    if volume == .wholeBook { return book.hasWebReadingCopy && book.webCacheCompleted == true }
    return volume.chapterURLs.allSatisfy { published.contains(WebChapterAddress.identity($0)) }
  }

  // 进度行显示已经落盘的章节，方便继续选择下载过一部分的卷。
  private func volumeRow(_ volume: WebBookVolume, cached: Bool) -> some View {
    let downloaded = book.downloadedWebChapters(in: volume).count
    return Group {
      if cached {
        LabeledContent(volume.title, value: "已缓存")
      } else {
        Toggle(isOn: Binding(get: { selection.contains(volume.id) }, set: { selected in
          if selected { selection.insert(volume.id) } else { selection.remove(volume.id) }
        })) {
          VStack(alignment: .leading, spacing: 4) {
            Text(volume.title)
            if !volume.chapterURLs.isEmpty {
              Text(downloaded == 0 ? "\(volume.chapterURLs.count) 章" : "已下载 \(downloaded) / \(volume.chapterURLs.count) 章")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }

  // 目录读取随面板取消，关闭或跳过时不接触正文缓存。
  private func loadCatalog() async {
    guard book.webVolumes == nil, let source = book.webURL else { return }
    directoryUnavailable = false
    selection = []
    error = nil
    do {
      let volumes = try await WebReaderNavigation(model: model).loadVolumes(at: source)
      try Task.checkCancellation()
      catalog = volumes
    } catch is CancellationError {} catch { directoryUnavailable = true }
  }

  // 确认后停止同一本书的旧任务，再以最新选择入队。提交失败时恢复此前仍在运行的任务。
  private func confirm() {
    guard !confirming, !selection.isEmpty, let repository = model.repository else { return }
    let selected = selection
    confirming = true
    error = nil
    Task {
      let wasRunning = await model.webBookCache.pauseAndWait(book.id)
      defer { confirming = false }
      do {
        let updated = try await repository.chooseWebCacheVolumes(selected, for: book, catalog: catalog)
        onConfirm(updated)
        dismiss()
      } catch {
        if wasRunning, let latest = try? await repository.book(book.id) { model.webBookCache.start(latest) }
        self.error = error.localizedDescription
      }
    }
  }
}
