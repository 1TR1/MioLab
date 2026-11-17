import MioLibCore
import PDFKit
import ReadiumNavigator
import SwiftUI

// 书架封面来源包含子书架；只展示有实际封面的书，选择后交给原有裁切与独立保存流程。
struct FolderBookCoverPicker: View {
  @ObservedObject var model: AppModel
  let folderID: UUID
  let onPick: (URL) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  private var books: [Book] {
    let ids = LibraryHierarchy.descendants(of: folderID, folders: model.folders)
    return model.books.filter {
      $0.folderID.map(ids.contains) == true && $0.effectiveCover != nil
        && (query.isEmpty || $0.title.localizedStandardContains(query)
          || $0.originalTitle.localizedStandardContains(query))
    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }
  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105, maximum: 160))], spacing: 22) {
          ForEach(books) { book in
            Button {
              if let url = model.fileURL(book.effectiveCover) { onPick(url); dismiss() }
            } label: {
              VStack(alignment: .leading, spacing: 8) {
                CoverView(url: model.fileURL(book.effectiveCover)).aspectRatio(2 / 3, contentMode: .fit)
                Text(book.title).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                Text(model.folderPath(book.folderID)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
              }
            }.buttonStyle(.plain)
          }
        }.padding()
      }
      .overlay {
        if books.isEmpty {
          ContentUnavailableView("没有可选的书籍封面", systemImage: "books.vertical",
            description: Text("包含当前书架及子书架。可先为书籍设置封面，再回来选择。"))
        }
      }
      .navigationTitle("选择书籍封面").navigationBarTitleDisplayMode(.inline)
      .searchable(text: $query, prompt: "搜索书架中的书籍")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
    }
  }
}

// 封面选择是独立预览会话，翻页、跳章节或跳 PDF 页码均不改变正常阅读的进度与历史。
struct BookPageCoverPicker: View {
  @StateObject private var session: ReaderSession
  let onPick: (UIImage) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var contents = false
  @State private var capturing = false
  @State private var turning = false
  @State private var slider = 0.0
  @State private var page = ""
  init(model: AppModel, book: Book, onPick: @escaping (UIImage) -> Void) {
    _session = StateObject(wrappedValue: ReaderSession(model: model, book: book, savesProgress: false))
    self.onPick = onPick
  }
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ReaderSurface(session: session)
          .overlay { if session.loading { ProgressView("正在加载书页…") } }
        VStack(spacing: 10) {
          HStack {
            Text(session.positionLabel.isEmpty ? "翻到想用作封面的书页" : session.positionLabel)
              .font(.caption).lineLimit(1)
            Spacer()
            Text("\(ReadingProgress.percent(session.progress))%").font(.caption).monospacedDigit()
          }.foregroundStyle(.secondary)
          Slider(value: $slider, in: 0...1, onEditingChanged: { editing in
            if !editing { session.seek(slider) }
          }).accessibilityLabel("选择封面书页位置")
          HStack {
            Button("上一页", systemImage: "chevron.backward") { turn(forward: false) }
            Spacer()
            Button("目录／缩略图") { contents = true }
            Spacer()
            Button("下一页", systemImage: "chevron.forward") { turn(forward: true) }
          }.font(.subheadline)
          if let document = session.host.pdfView?.document {
            HStack {
              TextField("页码 1～\(document.pageCount)", text: $page).keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
              Button("跳转") {
                if let value = Int(page), (1...document.pageCount).contains(value) {
                  session.host.goPDF(page: value - 1)
                }
              }.disabled(Int(page) == nil)
            }
          }
          Text("只截取书页内容；下一步可裁切。阅读位置会保留。")
            .font(.footnote).foregroundStyle(.secondary)
        }.padding().background(.bar).disabled(session.loading || capturing || turning)
      }
      .navigationTitle("从书页选择封面").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(capturing) }
        ToolbarItem(placement: .confirmationAction) {
          Button("选用此页") { capture() }.disabled(session.loading || capturing || turning)
        }
      }
      .overlay { if capturing { ProgressView("正在截取书页…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
      .interactiveDismissDisabled(capturing)
      .sheet(isPresented: $contents) { ReaderContentsView(session: session) }
      .alert("无法选用此页", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
        Button("好", role: .cancel) { session.error = nil }
      } message: { Text(session.error ?? "") }
      .onChange(of: session.progress) { _, value in slider = value }
      .onDisappear { session.close() }
    }
  }

  // 前后翻页委托给原始阅读引擎，固定版式和可重排书籍使用一致的选择入口。
  private func turn(forward: Bool) {
    turning = true
    Task {
      defer { turning = false }
      if let pdf = session.host.pdfView, let document = pdf.document, let page = pdf.currentPage {
        session.host.goPDF(page: document.index(for: page) + (forward ? 1 : -1))
      } else if let epub = session.host.epub {
        if forward { _ = await epub.goForward() } else { _ = await epub.goBackward() }
      }
    }
  }
  private func capture() {
    capturing = true
    Task {
      defer { capturing = false }
      do { onPick(try await session.host.currentPageImage()); dismiss() }
      catch { session.error = error.localizedDescription }
    }
  }
}
