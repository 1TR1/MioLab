import MioLibCore
import SwiftUI

// 收藏列表既可直接访问已有链接，也可先打开浏览器，在实际阅读页保存当前地址。
struct WebLibraryView: View {
  @ObservedObject var model: AppModel
  @State private var query = ""
  @State private var browser: WebBrowserDestination?
  @State private var editor: WebBookmarkDraft?
  @State private var deleting: WebBookmark?
  // 导出面板和普通书籍编辑共用书库模型，收藏删除不会影响已经导出的书籍。
  @State private var exporting: WebBookmark?
  @State private var exported: Book?
  @State private var pendingExport: Book?
  @State private var metadata: MetadataTarget?
  private var visible: [WebBookmark] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return model.webBookmarks.filter {
      term.isEmpty || $0.title.localizedCaseInsensitiveContains(term) || $0.url.absoluteString.localizedCaseInsensitiveContains(term)
    }
  }

  // 空列表保留明显的浏览入口，搜索则同时匹配标题和网址。
  var body: some View {
    List {
      Section {
        Button { browser = WebBrowserDestination() } label: {
          Label("打开内置浏览器", systemImage: "globe").padding(.vertical, 6)
        }
        Button { editor = WebBookmarkDraft() } label: { Label("添加网址收藏", systemImage: "bookmark.badge.plus") }
      } footer: {
        Text("在浏览器中保存链接。长按或侧滑已保存的网址可导出至书架，再选择原网页或水平翻页阅读模式。")
      }
      Section("已保存的网址 · \(visible.count)") {
        ForEach(visible) { bookmark in
          Button { browser = WebBrowserDestination(url: bookmark.url) } label: {
            HStack(spacing: 12) {
              Image(systemName: "doc.text").font(.title3).foregroundStyle(.blue).frame(width: 32)
              VStack(alignment: .leading, spacing: 5) {
                Text(bookmark.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                Text(bookmark.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let date = bookmark.lastOpenedAt {
                  Text("上次阅读 \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
                }
              }
              Spacer(minLength: 0)
              Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(.vertical, 5).contentShape(Rectangle())
          }.buttonStyle(.plain)
            .contextMenu {
              Button("导出至书架", systemImage: "books.vertical") { exporting = bookmark }
              Button("编辑收藏", systemImage: "pencil") { editor = WebBookmarkDraft(bookmark) }
              ShareLink(item: bookmark.url) { Label("分享链接", systemImage: "square.and.arrow.up") }
              Button("删除收藏", systemImage: "trash", role: .destructive) { deleting = bookmark }
            }
            .swipeActions {
              Button("删除", role: .destructive) { deleting = bookmark }
              Button("编辑") { editor = WebBookmarkDraft(bookmark) }.tint(.blue)
            }
            .swipeActions(edge: .leading) {
              Button("导出至书架", systemImage: "books.vertical") { exporting = bookmark }.tint(.green)
            }
        }
        if visible.isEmpty {
          ContentUnavailableView(query.isEmpty ? "还没有网址收藏" : "未找到网址", systemImage: "bookmark",
            description: Text(query.isEmpty ? "添加链接，随时回来继续阅读。" : "试试网页标题或域名。"))
        }
      }
    }.navigationTitle("网页阅读").searchable(text: $query, prompt: "搜索标题或网址")
      .fullScreenCover(item: $browser) { WebBrowserScreen(model: model, initialURL: $0.url) }
      .sheet(item: $editor) { WebBookmarkEditor(model: model, draft: $0) }
      .sheet(item: $exporting, onDismiss: { exported = pendingExport; pendingExport = nil }) { bookmark in
        WebBookmarkExportView(model: model, bookmark: bookmark) { pendingExport = $0 }
      }
      .sheet(item: $metadata) { MetadataEditor(model: model, target: $0) }
      .alert("已保存至书架", isPresented: Binding(get: { exported != nil }, set: { if !$0 { exported = nil } })) {
        if let book = exported {
          Button("编辑书籍") { metadata = .book(book); exported = nil }
        }
        Button("好", role: .cancel) { exported = nil }
      } message: { Text("可在书架中打开，或编辑标题、封面和链接。重复导出会保留已有书籍。") }
      .confirmationDialog("删除这个网址收藏？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
        if let bookmark = deleting {
          Button("删除收藏", role: .destructive) {
            model.run { try await $0.deleteWebBookmark(bookmark.id) }
            deleting = nil
          }
        }
        Button("取消", role: .cancel) { deleting = nil }
      }
  }
}

// 导出只保存书目与书架位置，卷目录在打开书籍的选择面板中读取。
struct WebBookmarkExportView: View {
  @ObservedObject var model: AppModel
  let bookmark: WebBookmark
  let onExport: (Book) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var folderID: UUID?
  @State private var choosingFolder = false
  @State private var saving = false
  @State private var error: String?
  var body: some View {
    NavigationStack {
      Form {
        Section("网页书籍") {
          Text(bookmark.title).font(.headline)
          Text(bookmark.url.absoluteString).font(.footnote).foregroundStyle(.secondary)
        }
        Section("保存位置") {
          Button { choosingFolder = true } label: {
            LabeledContent("目标书架", value: model.folderPath(folderID))
          }
        }
        if let error { Section { Text(error).foregroundStyle(.red) } }
      }.navigationTitle("导出至书架").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
          ToolbarItem(placement: .confirmationAction) {
            Button("导出") { save() }.disabled(saving || model.maintenance)
          }
        }
        .sheet(isPresented: $choosingFolder) {
          FolderPicker(model: model, title: "选择目标书架") { folderID = $0 }
        }
    }.interactiveDismissDisabled(saving)
  }

  // 新书以空缓存选择导出。重复导出时，数据库复用原书和已保存的缓存。
  private func save() {
    guard let repository = model.repository else { error = "书库尚未就绪"; return }
    saving = true
    Task {
      defer { saving = false }
      do {
        let result = try await repository.exportWebBookmarkToShelf(bookmark.id, folderID: folderID, selectedVolumes: [])
        try await model.reload()
        onExport(result)
        dismiss()
      } catch { self.error = error.localizedDescription }
    }
  }
}

// 每次打开拥有独立展示 ID，收藏网址本身继续使用数据库 ID。
struct WebBrowserDestination: Identifiable {
  let id = UUID()
  var url: URL? = nil
}
struct WebBookmarkDraft: Identifiable {
  let id = UUID()
  var bookmarkID: UUID?
  var title = ""
  var address = ""
  init() {}
  init(_ bookmark: WebBookmark) {
    bookmarkID = bookmark.id
    title = bookmark.title
    address = bookmark.url.absoluteString
  }
  init(title: String, url: URL) { self.title = title; address = url.absoluteString }
}

// 添加和编辑共用表单，错误显示在面板内，保存成功才关闭。
struct WebBookmarkEditor: View {
  @ObservedObject var model: AppModel
  @State var draft: WebBookmarkDraft
  @Environment(\.dismiss) private var dismiss
  @State private var saving = false
  @State private var error: String?
  var body: some View {
    NavigationStack {
      Form {
        Section("网址") {
          TextField("https://example.com", text: $draft.address, axis: .vertical)
            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        Section("标题") { TextField("留空使用网站域名", text: $draft.title) }
        if let error { Section { Text(error).foregroundStyle(.red) } }
        Section { Text("保存的是网页链接；收藏与广告过滤开关会随完整书库备份保存。").font(.footnote).foregroundStyle(.secondary) }
      }.navigationTitle(draft.bookmarkID == nil ? "收藏网址" : "编辑收藏").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
          ToolbarItem(placement: .confirmationAction) {
            Button("保存") { save() }.disabled(saving || draft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.maintenance)
          }
        }
    }.interactiveDismissDisabled(saving)
  }

  // 数据库写入后先刷新共享模型，关闭浏览器仍可在收藏列表看到新记录。
  private func save() {
    guard let repository = model.repository else { error = "书库尚未就绪"; return }
    saving = true
    Task {
      defer { saving = false }
      do {
        try await repository.saveWebBookmark(address: draft.address, title: draft.title, id: draft.bookmarkID)
        try await model.reload()
        dismiss()
      } catch { self.error = error.localizedDescription }
    }
  }
}
