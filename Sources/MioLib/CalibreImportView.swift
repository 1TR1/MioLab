import MioLibCore
import SwiftUI

// 浏览与下载由独立任务管理；关闭目录或取消传输时中止网络请求。
@MainActor final class CalibreBrowser: ObservableObject {
  @Published var catalog: CalibreCatalog?
  @Published var loading = false
  @Published var downloading = false
  @Published var message: String?
  @Published var selected: Set<String> = []
  @Published var formats: [String: BookFormat] = [:]
  @Published var downloadProgress = 0.0
  @Published var downloadStatus = ""
  @Published var failures: [String: String] = [:]
  @Published var enqueued = 0
  @Published private(set) var history: [URL] = []
  private var client: CalibreClient?
  private var browseTask: Task<Void, Never>?
  private var downloadTask: Task<Void, Never>?
  private var searchTemplate: String?

  // 连通后才替换当前书库；用户名和密码只交给当前连接的网络客户端。
  func connect(address: String, username: String, password: String) {
    guard !downloading else { return }
    do {
      let connection = try CalibreConnection(address: address, username: username, password: password)
      client = CalibreClient(connection: connection)
      history = []
      catalog = nil
      searchTemplate = nil
      open(connection.catalogURL)
    } catch { message = error.localizedDescription }
  }

  // 分类切换清空选择；翻页按稳定 ID 合并，避免服务器重复条目产生重复选中。
  func open(_ url: URL, append: Bool = false, push: Bool = true) {
    guard let client, !loading, !downloading else { return }
    loading = true
    message = nil
    browseTask = Task {
      defer { loading = false }
      do {
        let page = try await client.catalog(at: url)
        try Task.checkCancellation()
        if append, var current = catalog {
          var ids = Set(current.entries.map(\.id))
          current.entries += page.entries.filter { ids.insert($0.id).inserted }
          current.nextURL = page.nextURL
          catalog = current
        } else {
          catalog = page
          selected = []
          formats = [:]
          failures = [:]
          if push { history.append(url) }
        }
        if let template = page.searchTemplate { searchTemplate = template }
      } catch is CancellationError {} catch { message = error.localizedDescription }
    }
  }
  func back() {
    guard history.count > 1, !loading, !downloading else { return }
    history.removeLast()
    if let url = history.last { open(url, push: false) }
  }
  func search(_ text: String) {
    guard !loading, !downloading else { return }
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      if query.isEmpty, let root = client?.connection.catalogURL { open(root); return }
      var searchable = CalibreCatalog()
      searchable.searchTemplate = searchTemplate
      open(try searchable.searchURL(query: query))
    } catch { message = error.localizedDescription }
  }
  func download(for entry: CalibreEntry) -> CalibreDownload? {
    entry.downloads.first { $0.format == formats[entry.id] } ?? entry.preferredDownload
  }

  // 每次只下载一本，完整写盘后加入统一导入队列；单本错误保留选择，便于重试。
  func importSelected(model: AppModel, folderID: UUID?) {
    guard let client, let catalog, !downloading, !loading, !model.maintenance else { return }
    let entries = catalog.entries.filter { selected.contains($0.id) && download(for: $0) != nil }
    guard !entries.isEmpty else { return }
    downloading = true
    failures = [:]
    enqueued = 0
    downloadTask = Task {
      defer { downloading = false }
      for (index, entry) in entries.enumerated() {
        if Task.isCancelled { break }
        guard let format = download(for: entry) else { continue }
        downloadProgress = 0
        downloadStatus = "\(index + 1)/\(entries.count) · \(entry.title)"
        do {
          let url = try await client.download(format, title: entry.title) { value in
            Task { @MainActor in self.downloadProgress = value }
          }
          defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
          try Task.checkCancellation()
          try await model.enqueueCalibreDownload(url, folderID: folderID)
          enqueued += 1
          selected.remove(entry.id)
        } catch is CancellationError { break }
        catch { failures[entry.id] = error.localizedDescription }
      }
      downloadStatus = "已加入导入队列 \(enqueued) 本" + (failures.isEmpty ? "" : "，失败 \(failures.count) 本，可重试")
    }
  }
  func cancelDownloads() { downloadTask?.cancel() }
  func cancel() { browseTask?.cancel(); downloadTask?.cancel() }
}

// 地址与用户名保存在本机；密码仅留在当前面板内存中，不写设置、备份或日志。
struct CalibreImportView: View {
  @ObservedObject var model: AppModel
  let initialFolder: UUID?
  @Environment(\.dismiss) private var dismiss
  @StateObject private var browser = CalibreBrowser()
  @AppStorage("calibre.serverAddress") private var address = ""
  @AppStorage("calibre.username") private var username = ""
  @State private var password = ""
  @State private var query = ""
  @State private var folderID: UUID?
  @State private var choosingFolder = false
  @State private var settingsExpanded = true

  var body: some View {
    NavigationStack {
      List {
        connectionSection
        if let message = browser.message {
          Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }
        if let catalog = browser.catalog {
          Section {
            HStack {
              if browser.history.count > 1 {
                Button { browser.back() } label: { Image(systemName: "chevron.backward") }
                  .accessibilityLabel("返回上级目录")
              }
              Text(catalog.title).font(.headline)
            }.disabled(browser.loading || browser.downloading)
            HStack {
              TextField("搜索 Calibre 书库", text: $query).submitLabel(.search)
                .onSubmit { browser.search(query) }
              Button { browser.search(query) } label: { Image(systemName: "magnifyingglass") }
                .accessibilityLabel("搜索 Calibre 书库")
            }.disabled(browser.loading || browser.downloading)
            Button("导入到：\(model.folderPath(folderID))") { choosingFolder = true }
              .disabled(browser.downloading)
            if catalog.entries.contains(where: { !$0.downloads.isEmpty }) {
              Button(browser.selected.isEmpty ? "选择已加载的书籍" : "取消选择") {
                browser.selected = browser.selected.isEmpty
                  ? Set(catalog.entries.filter { !$0.downloads.isEmpty }.map(\.id)) : []
              }.disabled(browser.downloading || browser.loading)
            }
          }
          Section("书库目录") {
            ForEach(catalog.entries) { entry in entryRow(entry) }
            if catalog.entries.isEmpty { Text("此目录没有可导入的书籍").foregroundStyle(.secondary) }
            if let next = catalog.nextURL {
              Button("加载更多") { browser.open(next, append: true, push: false) }
                .disabled(browser.loading || browser.downloading)
            }
          }
        }
        if browser.loading { Section { ProgressView("正在连接书库…") } }
        if !browser.downloadStatus.isEmpty {
          Section {
            Text(browser.downloadStatus).font(.subheadline)
            if browser.downloading {
              ProgressView(value: browser.downloadProgress)
              Button("停止下载", role: .destructive) { browser.cancelDownloads() }
            } else if browser.enqueued > 0 {
              Text("已下载的书籍正在解析，完成后会显示在目标书架。导入结果可在书架的导入记录查看。")
                .font(.footnote).foregroundStyle(.secondary)
            }
          }
        }
      }
      .navigationTitle("Calibre 导入").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("完成") { browser.cancel(); dismiss() }.disabled(browser.downloading)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("导入 \(browser.selected.count) 本") { browser.importSelected(model: model, folderID: folderID) }
            .disabled(browser.selected.isEmpty || browser.loading || browser.downloading || model.maintenance)
        }
      }
      .interactiveDismissDisabled(browser.downloading)
      .sheet(isPresented: $choosingFolder) {
        FolderPicker(model: model, title: "选择导入位置") { folderID = $0 }
      }
      .task { folderID = initialFolder }
      .onDisappear { browser.cancel() }
    }
  }

  // 使用与 Calibre 相同的内容服务器地址，初次访问时由 iOS 请求本地网络权限。
  private var connectionSection: some View {
    Section {
      DisclosureGroup("服务器设置", isExpanded: $settingsExpanded) {
        TextField("http://电脑 IP:8080", text: $address)
          .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        TextField("用户名（可选）", text: $username)
          .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
        SecureField("密码（可选，仅用于本次连接）", text: $password).textContentType(.password)
        Button("连接书库") { browser.connect(address: address, username: username, password: password) }
          .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || browser.loading || browser.downloading)
      }.disabled(browser.downloading)
    } footer: {
      Text("电脑 Calibre：连接／共享 → 启动内容服务器。手机与电脑连接同一 Wi-Fi，再填写电脑的服务器地址；支持自动补齐 /opds。")
    }
  }

  // 导航条目进入子分类；书籍行选择下载，格式菜单允许覆盖默认 EPUB 优先规则。
  private func entryRow(_ entry: CalibreEntry) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        if !entry.downloads.isEmpty {
          if !browser.selected.insert(entry.id).inserted { browser.selected.remove(entry.id) }
        } else if let url = entry.navigationURL { browser.open(url) }
      } label: {
        HStack(spacing: 12) {
          Image(systemName: entry.downloads.isEmpty ? "folder" : browser.selected.contains(entry.id) ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(.tint)
          VStack(alignment: .leading, spacing: 3) {
            Text(entry.title).foregroundStyle(.primary)
            if !entry.authors.isEmpty {
              Text(entry.authors.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
            }
          }
          Spacer()
          if entry.downloads.isEmpty { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).disabled(browser.loading || browser.downloading)
      if let selected = browser.download(for: entry) {
        Menu {
          ForEach(entry.downloads) { item in
            Button(item.format.label) { browser.formats[entry.id] = item.format }
          }
        } label: {
          Label("格式：\(selected.format.label)", systemImage: "doc")
            .font(.caption)
        }.disabled(browser.downloading)
      }
      if let error = browser.failures[entry.id] {
        Text(error).font(.caption).foregroundStyle(.orange)
      }
    }.padding(.vertical, 3)
  }
}
