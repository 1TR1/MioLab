import MioLibCore
import PDFKit
import SwiftUI

// 会话通过 StateObject 保持稳定；工具栏的显隐仅执行短淡入淡出。
struct ReaderScreen: View {
  @ObservedObject var model: AppModel
  let book: Book
  @StateObject private var session: ReaderSession
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @State private var panel: ReaderPanel?
  @State private var cover: PickedCover?
  @State private var capturingCover = false
  init(model: AppModel, book: Book) {
    self.model = model
    self.book = book
    _session = StateObject(wrappedValue: ReaderSession(model: model, book: book))
  }
  var body: some View {
    ZStack {
      (model.preferences.theme == .paper
        ? Color(red: 0.96, green: 0.93, blue: 0.86) : Color(.systemBackground)).ignoresSafeArea()
      ReaderSurface(session: session).padding(.top, 58).padding(.bottom, 118)
      if session.loading {
        ProgressView("正在打开书籍…").padding(24).background(
          .regularMaterial, in: RoundedRectangle(cornerRadius: 18))
      }
      if session.controls {
        MioGlassGroup {
          VStack(spacing: 0) {
            topBar
            Spacer()
            bottomBar
          }.padding(.horizontal, 12).padding(.vertical, 6)
        }.transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
      }
    }
    .animation(reduceMotion ? nil : .spring(duration: 0.26, bounce: 0.15), value: session.controls)
    .statusBarHidden(!session.controls)
    .sheet(item: $panel) { item in
      switch item {
      case .contents: ReaderContentsView(session: session)
      case .search: ReaderSearchView(session: session)
      case .settings: ReaderSettingsView(model: model, isPDF: book.format == .pdf)
      case .notes: ReaderNotesView(session: session)
      }
    }
    .sheet(item: $session.draft) { AnnotationEditor(annotation: $0) { session.save($0) } }
    .sheet(item:$model.sharedItems){ShareSheet(items:$0.urls)}
    .fullScreenCover(item: $cover) { picked in
      CoverCropView(image: picked.image, aspect: 2 / 3) { data in
        model.run { try await $0.updateBookMetadata(book.id, coverData: data) }
      }
    }
    .alert(
      "阅读提示",
      isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })
    ) {
      Button("好", role: .cancel) { session.error = nil }
    } message: {
      Text(session.error ?? "")
    }
    .onChange(of: model.preferences) { _, value in session.host.applyPreferences(value) }
    .onChange(of: scenePhase) { _, phase in if phase != .active { Task { await session.flush() } } }
    .onDisappear {
      Task { await session.flush() }
      session.close()
    }
  }
  private var topBar: some View {
    HStack(spacing: 18) {
      Button {
        Task {
          await session.flush()
          dismiss()
        }
      } label: {
        Image(systemName: "chevron.down").font(.headline).frame(width: 36, height: 36)
      }.accessibilityLabel("返回书架")
      Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(1).frame(maxWidth: .infinity)
      Menu {
        Button("添加书签", systemImage: "bookmark") { session.addBookmark() }
        Button("添加页级笔记", systemImage: "square.and.pencil") { session.pageNote() }
        Button("查看本书笔记", systemImage: "quote.bubble") { panel = .notes }
        Button("将本页设为封面", systemImage: "book.closed") { captureCover() }
          .disabled(session.loading || capturingCover)
        if let url = model.fileURL(book.originalPath) {
          ShareLink(item: url) { Label("导出原书", systemImage: "square.and.arrow.up") }
        }
      } label: {
        Image(systemName: "ellipsis.circle").font(.title3).frame(width: 36, height: 36)
      }.accessibilityLabel("阅读操作")
    }.padding(.horizontal, 10).frame(height: 46).mioGlass(radius: 28, interactive: true)
      .buttonStyle(FluidButtonStyle())
  }
  // 正在阅读时可直接使用当前页，省去重新打开书页选择器。
  private func captureCover() {
    capturingCover = true
    Task {
      defer { capturingCover = false }
      do { cover = PickedCover(image: try await session.host.currentPageImage()) }
      catch { session.error = error.localizedDescription }
    }
  }
  private var bottomBar: some View {
    VStack(spacing: 8) {
      HStack {
        Text(session.positionLabel).lineLimit(1)
        Spacer()
        Text("\(ReadingProgress.percent(session.progress))%").monospacedDigit()
      }.font(.caption).foregroundStyle(.secondary)
      Slider(
        value: Binding(get: { session.progress }, set: { session.progress = $0 }), in: 0...1,
        onEditingChanged: { if !$0 { session.seek(session.progress) } }
      ).accessibilityLabel("阅读进度")
      HStack {
        Button {
          panel = .contents
        } label: {
          Image(systemName: "list.bullet")
        }.accessibilityLabel("目录与页码")
        Spacer()
        Button {
          panel = .search
        } label: {
          Image(systemName: "magnifyingglass")
        }.accessibilityLabel("搜索书内文字")
        Spacer()
        Button {
          session.addBookmark()
        } label: {
          Image(systemName: "bookmark")
        }.accessibilityLabel("添加书签")
        Spacer()
        Button {
          panel = .notes
        } label: {
          Image(systemName: "quote.bubble")
        }.accessibilityLabel("本书笔记")
        Spacer()
        Button {
          panel = .settings
        } label: {
          Image(systemName: "textformat.size")
        }.accessibilityLabel("阅读设置")
      }.font(.title3).frame(height: 28)
    }.padding(.horizontal, 20).padding(.vertical, 12).mioGlass(radius: 32, interactive: true)
      .buttonStyle(FluidButtonStyle())
  }
}
enum ReaderPanel: String, Identifiable {
  case contents, search, settings, notes
  var id: String { rawValue }
}
// 正文恢复真实系统字号和自身字体设计，应用界面字号不会传入 Readium 或 PDFKit。
struct ReaderSurface: View {
  @ObservedObject var session: ReaderSession
  @Environment(\.systemReadingType) private var systemSize
  var body: some View {
    NativeReaderSurface(session: session).dynamicTypeSize(systemSize).fontDesign(nil)
  }
}
private struct NativeReaderSurface: UIViewControllerRepresentable {
  @ObservedObject var session: ReaderSession
  func makeUIViewController(context: Context) -> ReaderHostController { session.host }
  func updateUIViewController(_ controller: ReaderHostController, context: Context) {}
}

// 原生 PDF 缩略图独立呈现，章节目录不再与逐页列表混排。
struct PDFThumbnails: UIViewRepresentable {
  let pdf: PDFView
  func makeUIView(context: Context) -> PDFThumbnailView {
    let view = PDFThumbnailView()
    view.pdfView = pdf
    view.layoutMode = .vertical
    view.thumbnailSize = CGSize(width: 100, height: 140)
    return view
  }
  func updateUIView(_ view: PDFThumbnailView, context: Context) {}
}

// 搜索只渲染当前结果；点击结果先定位正文再收起面板。
struct ReaderSearchView: View {
  @ObservedObject var session: ReaderSession
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  var body: some View {
    NavigationStack {
      List {
        if session.searching { ProgressView("正在检索文字…") }
        if !session.searchMessage.isEmpty {
          Text(session.searchMessage).font(.caption).foregroundStyle(.secondary)
        }
        ForEach(session.matches) { match in
          Button {
            session.navigate(match)
            dismiss()
          } label: {
            VStack(alignment: .leading, spacing: 6) {
              Text(match.title).font(.caption).foregroundStyle(.secondary)
              Text(match.snippet).font(.subheadline).lineLimit(4).foregroundStyle(.primary)
            }
          }
        }
      }.navigationTitle("书内搜索").navigationBarTitleDisplayMode(.inline).searchable(
        text: $query, prompt: "搜索文字"
      )
      .onChange(of: query) { _, value in session.search(value) }
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
      .onDisappear { session.search("") }
    }
  }
}

// 原生表单编辑阅读偏好；固定版式 PDF 不显示不能生效的字体控制。
struct ReaderSettingsView: View {
  @ObservedObject var model: AppModel
  let isPDF: Bool
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        Section("主题") {
          Picker("配色", selection: binding(\.theme)) {
            ForEach(ReaderTheme.allCases, id: \.self) { Text($0.label).tag($0) }
          }
        }
        Section("阅读方式") {
          Picker("翻页", selection: binding(\.scroll)) {
            Text("水平分页").tag(false)
            Text("垂直滚动").tag(true)
          }.pickerStyle(.segmented)
        }
        if !isPDF {
          Section("文字排版") {
            Toggle("衬线字体", isOn: binding(\.serif))
            // 预览直接跟随当前字体和排版，调整前无需离开面板试读。
            Text("春日的光落在书页上。\n慢慢读，让每一页都从容。")
              .font(.system(size: 18 * model.preferences.fontSize / 100,
                            design: model.preferences.serif ? .serif : .default))
              .fontDesign(nil)
              .lineSpacing(4 * model.preferences.lineHeight)
              .padding(.horizontal, 12 * model.preferences.margins).padding(.vertical, 14)
              .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
              .background(model.preferences.theme == .paper ? Color(red: 0.97, green: 0.94, blue: 0.86)
                            : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
              .accessibilityLabel("字体预览：春日的光落在书页上。慢慢读，让每一页都从容。")
            MagneticSlider(title: "字号", value: binding(\.fontSize), stops: ReaderSnap.fontSizes,
                           display: "\(Int(model.preferences.fontSize))%", adjustmentButtons: true)
            MagneticSlider(title: "行距", value: binding(\.lineHeight), stops: ReaderSnap.lineHeights,
                           display: model.preferences.lineHeight.formatted(.number.precision(.fractionLength(1))),
                           adjustmentButtons: true)
            MagneticSlider(title: "页边距", value: binding(\.margins), stops: ReaderSnap.margins,
                           display: model.preferences.margins.formatted(.number.precision(.fractionLength(1))),
                           adjustmentButtons: true)
          }
        } else {
          Section { Text("PDF 保留原有页面版式，可双指缩放。").font(.footnote).foregroundStyle(.secondary) }
        }
      }.navigationTitle("阅读设置").navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
      }
    }.presentationDetents([.large]).presentationDragIndicator(.visible)
  }
  private func binding<T>(_ path: WritableKeyPath<ReaderPreferences, T>) -> Binding<T> {
    Binding(
      get: { model.preferences[keyPath: path] },
      set: {
        var value = model.preferences
        value[keyPath: path] = $0
        model.changePreferences(value)
      })
  }
}

// 本书笔记在当前会话内跳转，避免再次创建另一层阅读页面。
struct ReaderNotesView: View {
  @ObservedObject var session: ReaderSession
  @Environment(\.dismiss) private var dismiss
  @State private var editing: Annotation?
  var body: some View {
    NavigationStack {
      List {
        ForEach(session.notes) { note in
          Button {
            session.navigate(note)
            dismiss()
          } label: {
            VStack(alignment: .leading, spacing: 6) {
              Label(
                note.chapter.isEmpty ? "正文" : note.chapter,
                systemImage: note.kind == .bookmark ? "bookmark.fill" : "highlighter"
              ).font(.caption).foregroundStyle(.secondary)
              if !note.quote.isEmpty { Text(note.quote).lineLimit(4).foregroundStyle(.primary) }
              if !note.note.isEmpty {
                Text(note.note).font(.subheadline).foregroundStyle(.secondary)
              }
            }
          }.contextMenu {
            Button("编辑批注") { editing = note }
            Button("删除", role: .destructive) { session.remove(note) }
          }.swipeActions { Button("删除", role: .destructive) { session.remove(note) } }
        }
      }.overlay {
        if session.notes.isEmpty { ContentUnavailableView("还没有笔记", systemImage: "quote.bubble") }
      }
      .navigationTitle("本书笔记").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            session.model.exportNotes(bookID: session.book.id, markdown: true)
          } label: {
            Image(systemName: "square.and.arrow.up")
          }
        }
      }
      .sheet(item: $editing) { AnnotationEditor(annotation: $0) { session.save($0) } }
    }
  }
}
