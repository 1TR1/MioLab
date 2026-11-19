import MioLibCore
import PDFKit
import SwiftUI

// 会话通过 StateObject 保持稳定；工具栏的显隐仅执行短淡入淡出。
struct ReaderScreen: View {
  @ObservedObject var model: AppModel
  let book: Book
  // 普通电子书不传入网络导航；网页书籍按需加载并在同一个阅读窗口替换聚合副本。
  let webNavigation: WebReaderNavigation?
  let onWebBookChange: ((Book, ReaderPanel?) -> Void)?
  let onShowOriginalPage: ((URL) async -> Void)?
  let onChooseCacheVolumes: (() async throws -> Void)?
  @StateObject private var session: ReaderSession
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @State private var panel: ReaderPanel?
  @State private var cover: PickedCover?
  @State private var capturingCover = false
  @State private var changingChapter = false
  @State private var chapterTask: Task<Void, Never>?
  @State private var requestedPanel: ReaderPanel?
  init(model: AppModel, book: Book, webNavigation: WebReaderNavigation? = nil,
    initialPanel: ReaderPanel? = nil, onShowOriginalPage: ((URL) async -> Void)? = nil,
    onChooseCacheVolumes: (() async throws -> Void)? = nil,
    onWebBookChange: ((Book, ReaderPanel?) -> Void)? = nil)
  {
    self.model = model
    self.book = book
    self.webNavigation = webNavigation
    self.onWebBookChange = onWebBookChange
    self.onShowOriginalPage = onShowOriginalPage
    self.onChooseCacheVolumes = onChooseCacheVolumes
    _session = StateObject(wrappedValue: ReaderSession(model: model, book: book))
    _requestedPanel = State(initialValue: initialPanel)
  }
  var body: some View {
    GeometryReader { geometry in
      let palette = ReaderPagePalette(theme: model.preferences.theme)
      // 翻页顺序之外的独立尾注页会在自己的窗口显示返回栏。
      let showFootnoteReturn = session.footnoteReturnLocation != nil && session.footnoteDocument == nil
      ZStack {
        // 容器遵守系统安全区，摄像头、刘海、灵动岛及横屏侧边避让由系统提供。
        VStack(spacing: 0) {
          Button { session.controls.toggle() } label: {
            Text(session.positionLabel.isEmpty ? book.title : session.positionLabel)
              .font(.system(size: 12)).lineLimit(1)
              .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
              .contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityLabel("显示阅读工具栏")
            .padding(.horizontal, pageMargin(geometry.size.width))
            .padding(.top, 16)
            .opacity(session.controls ? 0 : 1).allowsHitTesting(!session.controls)
          // 正文在页眉和页脚之间额外留出上下各 24 点，工具栏显隐时保留同一页高。
          ReaderSurface(session: session)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 24)
          ReaderPageFooter(session: session)
            .padding(.horizontal, pageMargin(geometry.size.width))
            .padding(.bottom, 8)
            .opacity(session.controls ? 0 : 1)
        }
        .foregroundStyle(palette.ink.opacity(0.7))
        .dynamicTypeSize(.large).fontDesign(.default)
        if session.loading {
          ProgressView("正在打开书籍…").padding(24).background(
            .regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
        // 加载过程中保留当前页与取消入口，失败或取消不关闭原来的阅读模式。
        if changingChapter {
          Color.black.opacity(0.12).ignoresSafeArea()
          VStack(spacing: 14) {
            ProgressView("正在打开章节…")
            Button("取消") { chapterTask?.cancel() }
          }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      // 只有装饰背景延伸到屏幕边缘，不能把忽略安全区传播给正文和按钮。
      .background(palette.background.ignoresSafeArea())
      // 分别锚定上下边缘，避免共享 Spacer 或玻璃容器将工具栏错误地放到中间。
      .overlay(alignment: .top) {
        if session.controls || showFootnoteReturn {
          VStack(spacing: 8) {
            if session.controls {
              MioGlassGroup { topBar }.fixedSize(horizontal: false, vertical: true)
            }
            // 注释返回栏单独常驻，打开阅读工具栏时排在它的下方。
            if showFootnoteReturn {
              ReaderFootnoteReturnBar(palette: palette, busy: session.navigatingFootnote,
                undo: session.undoFootnoteJump, close: session.dismissFootnoteReturnBar)
            }
          }.padding(.horizontal, 12).padding(.top, 8).transition(.opacity)
        }
      }
      .overlay(alignment: .bottom) {
        if session.controls {
          MioGlassGroup { bottomBar }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.bottom, 8).transition(.opacity).disabled(changingChapter)
        }
      }
      .accessibilityHidden(session.footnotePreview != nil)
      // 小窗在阅读窗口内居中，阅读窗口只提供可用尺寸。
      .overlay {
        footnoteOverlay(palette: palette, size: geometry.size)
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: session.controls)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: session.footnoteReturnLocation != nil)
    .statusBarHidden(true)
    .interactiveDismissDisabled(changingChapter)
    .sheet(item: $panel) { item in
      switch item {
      case .contents: ReaderContentsView(session: session)
      case .search: ReaderSearchView(session: session)
      case .settings: ReaderSettingsView(model: model, isPDF: book.format == .pdf)
      case .notes: ReaderNotesView(session: session)
      }
    }
    // 单独排版的尾注页可滑动关闭，返回下方仍在原位的正文。
    .sheet(item: $session.footnoteDocument, onDismiss: session.dismissFootnoteReturnBar) { document in
      ReaderFootnoteDocumentView(session: session, document: document,
        palette: ReaderPagePalette(theme: model.preferences.theme))
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
      if let source = webNavigation?.returnURL ?? session.currentWebChapter?.url ?? book.webURL {
        Button("在原网页查看") { showOriginalPage(source) }
      }
    } message: {
      Text(session.error ?? "")
    }
    // 照片权限和结果留在单独的提示中，读者可继续在原页阅读。
    .alert("保存图片", isPresented: Binding(get: { session.imageSaveNotice != nil },
      set: { if !$0 { session.imageSaveNotice = nil } })) {
      Button("好", role: .cancel) { session.imageSaveNotice = nil }
    } message: { Text(session.imageSaveNotice ?? "") }
    .onChange(of: model.preferences) { _, value in session.host.applyPreferences(value) }
    // 请求完整目录或搜索时等新 EPUB 完成解析，再呈现相应面板。
    .onChange(of: session.loading) { _, loading in
      if !loading, session.error == nil, let requestedPanel {
        panel = requestedPanel
        self.requestedPanel = nil
      }
    }
    .onChange(of: scenePhase) { _, phase in if phase != .active { Task { await session.flush() } } }
    .onDisappear {
      chapterTask?.cancel()
      Task { await session.flush() }
      session.close()
    }
  }
  // 注释小窗按内容测量高度，安全区留白只限制其可用上限。
  private func footnoteOverlay(palette: ReaderPagePalette, size: CGSize) -> some View {
    let horizontalInset: CGFloat = size.width < 380 ? 16 : 24
    let verticalInset: CGFloat = size.height < 380 ? 12 : 24
    let width = min(480, max(0, size.width - 2 * horizontalInset))
    let heightLimit = max(0, size.height - 2 * verticalInset)
    let visible = session.footnotePreview != nil
    let fade = Animation.easeOut(duration: 0.16)
    return ZStack {
      // 遮罩单独淡入淡出，点窗外可关闭小窗。
      ZStack {
        if visible {
          Color.black.opacity(0.16).ignoresSafeArea()
            .onTapGesture { session.dismissFootnotePreview() }
            .accessibilityHidden(true)
            .transition(.opacity)
        }
      }.animation(fade, value: visible)

      // 小窗以自身中心弹出，系统开启减弱动态效果时只改变透明度。
      ZStack {
        if let footnote = session.footnotePreview {
          ReaderFootnoteCard(footnote: footnote, palette: palette,
            heightLimit: heightLimit, jumping: session.navigatingFootnote,
            close: session.dismissFootnotePreview, jump: { session.jumpToFootnote(footnote.link) })
            .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
        }
      }
      // 只给卡片内部传递高度上限，固定尺寸的定位区域不绘制玻璃。
      .frame(width: width, height: heightLimit)
      .animation(visible && !reduceMotion ? .spring(duration: 0.30, bounce: 0.14) : fade, value: visible)
    }
    .frame(width: size.width, height: size.height)
    .allowsHitTesting(visible)
  }

  // 左右留白与 Readium 的 20 点基准一致，小屏和大边距设置仍保留可读宽度。
  private func pageMargin(_ width: CGFloat) -> CGFloat {
    min(width * 0.2, max(10, 20 * model.preferences.margins))
  }
  private var topBar: some View {
    HStack(spacing: 18) {
      Button {
        // 换章请求可以取消，退出书籍时直接返回打开前的界面。
        chapterTask?.cancel()
        Task {
          await session.flush()
          dismiss()
        }
      } label: {
        Image(systemName: "chevron.down").font(.headline).frame(width: 36, height: 36)
      }.accessibilityLabel("退出阅读，返回书架")
      Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(1).frame(maxWidth: .infinity)
      Menu {
        if webNavigation != nil {
          Button("上一章", systemImage: "backward.end") { changeChapter(.previous) }.disabled(session.loading)
          Button("下一章", systemImage: "forward.end") { changeChapter(.next) }.disabled(session.loading)
        }
        // 网页书的缓存入口交给外层书籍窗口，避免切回原网页或重建阅读器。
        if let onChooseCacheVolumes {
          Button("选择缓存卷", systemImage: "arrow.down.circle") {
            Task {
              do { try await onChooseCacheVolumes() }
              catch is CancellationError {} catch { session.error = error.localizedDescription }
            }
          }.disabled(model.maintenance)
        }
        Button("添加书签", systemImage: "bookmark") { session.addBookmark() }
        Button("添加页级笔记", systemImage: "square.and.pencil") { session.pageNote() }
        Button("查看本书笔记", systemImage: "quote.bubble") { panel = .notes }
        Button("将本页设为封面", systemImage: "book.closed") { captureCover() }
          .disabled(session.loading || capturingCover)
        // 网页书籍可分享原链接及离线正文，避免导出内部链接描述文件。
        if let source = session.currentWebChapter?.url ?? book.webURL {
          Button("关闭阅读模式", systemImage: "globe") { showOriginalPage(source) }
          ShareLink(item: source) { Label("分享网页链接", systemImage: "square.and.arrow.up") }
          if let url = model.fileURL(book.readingPath) {
            ShareLink(item: url) { Label("导出正文 EPUB", systemImage: "doc.richtext") }
          }
        } else if let url = model.fileURL(book.originalPath) {
          ShareLink(item: url) { Label("导出原书", systemImage: "square.and.arrow.up") }
        }
      } label: {
        Image(systemName: "ellipsis.circle").font(.title3).frame(width: 36, height: 36)
      }.accessibilityLabel("阅读操作").disabled(changingChapter)
    }.padding(.horizontal, 10).frame(height: 46).mioGlass(radius: 28, interactive: true)
      .buttonStyle(FluidButtonStyle())
  }
  // 切回原网页前先写入准确的阅读位置，由书籍窗口负责保存模式开关和展示网页。
  private func showOriginalPage(_ url: URL) {
    Task {
      await session.flush()
      await onShowOriginalPage?(url)
    }
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
      // 章节按钮沿用阅读工具栏，水平翻页、字体和主题的操作保持不变。
      if webNavigation != nil {
        HStack {
          Button("上一章", systemImage: "chevron.backward") { changeChapter(.previous) }
          Spacer()
          WebReaderCacheCount(cache: model.webBookCache, book: book)
          Spacer()
          Button("下一章", systemImage: "chevron.forward") { changeChapter(.next) }
        }.font(.subheadline).frame(minHeight: 34).disabled(session.loading)
        Divider()
      }
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
          openPublicationPanel(.contents)
        } label: {
          Image(systemName: "list.bullet")
        }.accessibilityLabel("目录与页码")
        Spacer()
        Button {
          openPublicationPanel(.search)
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

  // 新章提交前冻结旧进度；换章成功才重建 Readium，旧会话退出时不会再覆盖目标位置。
  private func changeChapter(_ direction: WebChapterDirection) {
    guard let webNavigation, let onWebBookChange, !changingChapter else { return }
    changingChapter = true
    chapterTask = Task {
      await session.suspendForWebNavigation()
      defer { changingChapter = false; chapterTask = nil }
      do {
        try Task.checkCancellation()
        let updated = try await webNavigation.changeChapter(bookID: book.id,
          href: session.currentResourceHref, direction: direction)
        try Task.checkCancellation()
        try? await model.reload()
        try Task.checkCancellation()
        session.close()
        onWebBookChange(updated, nil)
      } catch is CancellationError {
        session.resumeAfterWebNavigation()
        await session.flush()
      }
      catch {
        session.resumeAfterWebNavigation()
        session.error = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
      }
    }
  }

  // 自动缓存完成时不打断正在读的页或文字选区。打开目录或搜索时采用完整副本并继承当前位置。
  private func openPublicationPanel(_ next: ReaderPanel) {
    guard !session.loading, !changingChapter else { return }
    guard let onWebBookChange, let repository = model.repository,
      let latest = model.books.first(where: { $0.id == book.id }), latest.readingPath != book.readingPath else {
      panel = next
      return
    }
    changingChapter = true
    chapterTask = Task {
      await session.suspendForWebNavigation()
      defer { changingChapter = false; chapterTask = nil }
      do {
        try Task.checkCancellation()
        let updated = try await repository.book(book.id)
        try Task.checkCancellation()
        guard updated.originalPath == book.originalPath else { throw LibraryError.message("网页书籍已改变，请重新打开") }
        session.close()
        onWebBookChange(updated, next)
      } catch {
        session.resumeAfterWebNavigation()
        if !Task.isCancelled { session.error = error.localizedDescription }
      }
    }
  }
}

// 阅读工具栏中的缓存章数独立观察下载状态，不改变翻页区域或重建会话。
private struct WebReaderCacheCount: View {
  @ObservedObject var cache: WebBookCache
  let book: Book
  var body: some View {
    let count = cache.statuses[book.id]?.count ?? book.downloadedWebChapters.count
    Text("已缓存 \(count) 章").foregroundStyle(.secondary).lineLimit(1)
      .minimumScaleFactor(0.75)
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
          // 注释方式即时作用于书内链接，并通过阅读偏好持久化。
          Section("注释") {
            Picker("注释链接", selection: binding(\.footnoteMode)) {
              ForEach(ReaderFootnoteMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
          }
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
