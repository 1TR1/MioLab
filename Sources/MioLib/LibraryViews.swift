import ImageIO
import MioLibCore
import SwiftUI
import UniformTypeIdentifiers

// 窄屏保留底部导航，大屏侧边栏使用系统的可收起分栏布局。
struct RootView: View {
  @ObservedObject var model: AppModel
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var section = 0
  @State private var shelfEditing = false
  var body: some View {
    VStack(spacing: 0) {
      // 导航栈和底栏分别占用实际高度，List 与 ScrollView 的可滚动范围在底栏上方结束。
      Group {
        if sizeClass == .regular {
          NavigationSplitView {
            List(selection:Binding<Int?>(get:{section},set:{section=$0 ?? 0})) {
              Label("书架", systemImage: "books.vertical").tag(0)
              Label("我的", systemImage: "person.crop.circle").tag(1)
            }.navigationTitle("MioLib")
          } detail: {
            NavigationStack { page }
          }
        } else {
          tabs
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
      // 撤销提示也参与布局，出现时为书架最后一行留出额外空间。
      if !model.undoIDs.isEmpty { undoBar }
      if sizeClass != .regular && (section != 0 || !shelfEditing) { MioTabDock(selection: $section) }
    }
    .onPreferenceChange(ShelfEditingKey.self) { shelfEditing = $0 }
    .sheet(isPresented: $model.importPresented) { ImportQueueView(model: model) }
    .sheet(item:Binding(get:{model.readerBook == nil ? model.sharedItems:nil},set:{model.sharedItems=$0})) { ShareSheet(items: $0.urls) }
    .fullScreenCover(item: $model.readerBook, onDismiss: { Task { try? await model.reload() } }) {
      // 网页书籍在一层窗口内按书目设置进入阅读模式或原网页。
      if $0.format == .web { WebBrowserScreen(model: model, initialURL: $0.webURL, book: $0) }
      else { ReaderScreen(model: model, book: $0) }
    }
    .alert(
      "MioLib",
      isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
    ) {
      Button("好", role: .cancel) { model.message = nil }
    } message: {
      Text(model.message ?? "")
    }
    .confirmationDialog(
      "恢复备份将替换当前书库",
      isPresented: Binding(
        get: { model.pendingBackup != nil }, set: { if !$0 { model.pendingBackup = nil } }),
      titleVisibility: .visible
    ) {
      if let backup = model.pendingBackup {
        Button("校验并恢复书库", role: .destructive) { model.restore(backup) }
      }
      Button("取消", role: .cancel) { model.pendingBackup = nil }
    } message: {
      Text("恢复前建议先导出当前书库备份。新备份校验失败时会保留当前数据。")
    }
    .overlay {
      if model.maintenance {
        ZStack {
          Color.black.opacity(0.15).ignoresSafeArea()
          ProgressView("正在处理书库，请稍候…").padding(28).background(
            .regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
      }
    }
  }
  // 撤销提示紧邻滚动区域，编辑模式隐藏自定义底栏后仍可使用。
  private var undoBar: some View {
    HStack {
      Text("已移除 \(model.undoIDs.count) 本书")
      Spacer()
      Button("撤销") { model.undoDelete() }
      Button { model.undoIDs = [] } label: { Image(systemName: "xmark") }
        .accessibilityLabel("关闭撤销提示")
    }.font(.subheadline).padding().background(.regularMaterial)
  }
  // 两个导航栈保留各自状态，底部只有一套自定义导航，子页面不再恢复旧系统底栏。
  private var tabs: some View {
    ZStack {
      NavigationStack { LibraryView(model: model) }
        .opacity(section == 0 ? 1 : 0).allowsHitTesting(section == 0)
        .accessibilityHidden(section != 0).zIndex(section == 0 ? 1 : 0)
      NavigationStack { MyView(model: model) }
        .opacity(section == 1 ? 1 : 0).allowsHitTesting(section == 1)
        .accessibilityHidden(section != 1).zIndex(section == 1 ? 1 : 0)
    }.animation(nil, value: section)
  }
  @ViewBuilder private var page: some View {
    switch section {
    case 1: MyView(model: model)
    default: LibraryView(model: model)
    }
  }
}

// 列表与封面模式均按书架导航；搜索始终覆盖全书库并显示原始路径。
struct LibraryView: View {
  @ObservedObject var model: AppModel
  var folderID: UUID? = nil
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var query = ""
  @State private var filter = 0
  @State private var picking = false
  @State private var usb = false
  // Calibre 与本地文件导入共用当前书架作为默认目标。
  @State private var calibre = false
  @State private var editing = false
  @State private var selected: Set<UUID> = []
  @State private var metadata: MetadataTarget?
  @State private var moving = false
  @State private var batchEditing = false
  @State private var folderMove: LibraryFolder?
  @State private var deleting: LibraryFolder?
  private var title: String {
    folderID.flatMap { id in model.folders.first { $0.id == id }?.title } ?? "书架"
  }
  private var children: [LibraryFolder] {
    model.folders.filter { $0.parentID == folderID }.sorted {
      $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
  }
  private var visible: [Book] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered = model.books.filter { book in
      if !term.isEmpty {
        return book.title.localizedCaseInsensitiveContains(term)
          || book.originalTitle.localizedCaseInsensitiveContains(term)
      }
      switch filter {
      case 1: return book.lastOpenedAt != nil
      case 2: return book.isFavorite
      case 3: return book.isFinished
      default: return book.folderID == folderID
      }
    }
    // 列表与书架四宫格共用排序规则，切换排序时两者同步更新。
    return model.preferences.bookSort.ordered(filtered)
  }
  var body: some View {
    Group {
      if model.preferences.shelfLayout == .covers {
        coversView
      } else {
        List {
          if folderID == nil && query.isEmpty { filterRow }
          if query.isEmpty && filter == 0 && !children.isEmpty {
            Section("书架") {
              // 书架与图书均使用原生列表行，保留导航、编辑菜单及侧滑操作。
              ForEach(children) { folder in folderRow(folder) }
            }
          }
          Section(query.isEmpty ? "\(visible.count) 本书" : "搜索结果 · \(visible.count) 本") {
            ForEach(visible) { book in bookRow(book) }
          }
        }.listStyle(.insetGrouped).scrollContentBackground(.hidden)
          .background(Color(.systemGroupedBackground))
      }
    }
    .overlay {
      if visible.isEmpty && (children.isEmpty || !query.isEmpty || filter != 0) {
        ContentUnavailableView(
          query.isEmpty ? "让阅读从这里开始" : "未找到书籍",
          systemImage: query.isEmpty ? "book.closed" : "magnifyingglass",
          description: Text(query.isEmpty ? "点击右上角 ＋，从其他 App、文件或电脑导入。" : "试试书籍的新标题或原始标题。"))
          .padding(.top, 70).allowsHitTesting(false)
      }
    }
    .navigationTitle(editing ? "已选择 \(selected.count) 本" : title)
    .searchable(text: $query, prompt: "搜索全书库的书名")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        // 网页阅读常驻书架工具栏，无须先导入文件或创建电子书。
        HStack {
          NavigationLink { WebLibraryView(model: model) } label: { Image(systemName: "globe") }
            .accessibilityLabel("网页阅读与网址收藏")
          Button(editing ? "完成" : "编辑") {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
              editing.toggle()
              selected = []
            }
          }.disabled(model.maintenance)
        }
      }
      ToolbarItemGroup(placement: .topBarTrailing) {
        Menu {
          Picker("排序", selection: preference(\.bookSort)) {
            ForEach(BookSort.allCases, id: \.self) { Text($0.label).tag($0) }
          }
          Picker("显示方式", selection: preference(\.shelfLayout)) {
            ForEach(ShelfLayout.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
          }
          // 独立切换书架封面样式，不改变当前列表或封面布局。
          Picker("书架封面", selection: preference(\.shelfCoverStyle)) {
            ForEach(ShelfCoverStyle.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
          }
          if !model.jobs.isEmpty {
            Button("导入记录", systemImage: "tray.and.arrow.down") { model.importPresented = true }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }.accessibilityLabel("书架选项")
        Menu {
          Button("从文件导入", systemImage: "doc.badge.plus") { picking = true }
          Button("电脑 USB 传书", systemImage: "cable.connector") { usb = true }
          Button("从 Calibre 导入", systemImage: "books.vertical") { calibre = true }
          Button("新建书架", systemImage: "folder.badge.plus") {
            metadata = .folder(LibraryFolder(parentID: folderID, title: ""))
          }
        } label: {
          Image(systemName: "plus")
        }.accessibilityLabel("导入与新建")
      }
      if editing {
        ToolbarItemGroup(placement: .bottomBar) {
          Button(selected.count == visible.count && !selected.isEmpty ? "取消全选" : "全选") {
            selected = selected.count == visible.count ? [] : Set(visible.map(\.id))
          }.disabled(visible.isEmpty)
          Spacer()
          Button("移动") { moving = true }.disabled(selected.isEmpty)
          Button("批量编辑") { batchEditing = true }.disabled(selected.isEmpty)
          Button("删除", role: .destructive) {
            model.trash(selected)
            selected = []
          }.disabled(selected.isEmpty)
        }
      }
    }
    .fileImporter(
      isPresented: $picking, allowedContentTypes: UTType.mioBooks, allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls): model.importURLs(urls, folderID: folderID)
      case .failure(let error): model.message = error.localizedDescription
      }
    }
    .sheet(isPresented: $usb) { USBImportView(model: model, initialFolder: folderID) }
    .sheet(isPresented: $calibre) { CalibreImportView(model: model, initialFolder: folderID) }
    .sheet(item: $metadata) { MetadataEditor(model: model, target: $0) }
    .sheet(isPresented: $moving) {
      FolderPicker(model: model, title: "移动 \(selected.count) 本书") { id in
        let ids = selected
        model.run { try await $0.moveBooks(ids, to: id) }
        selected = []
        editing = false
      }
    }
    .sheet(isPresented: $batchEditing) {
      BatchBookEditor(model: model, ids: selected) { selected = [] }
    }
    // 筛选、搜索或书目变化后只保留仍可见的选择，避免误改屏幕外的书籍。
    .onChange(of: visible.map(\.id)) { _, ids in selected.formIntersection(ids) }
    .preference(key: ShelfEditingKey.self, value: editing)
    .sheet(item: $folderMove) { folder in
      FolderPicker(model: model, title: "移动书架", excluding: descendants(folder.id)) { id in
        var updated = folder
        updated.parentID = id
        model.run { try await $0.saveFolder(updated) }
      }
    }
    .confirmationDialog(
      "删除书架及其子书架？",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible
    ) {
      if let folder = deleting {
        Button("删除书架，保留书籍", role: .destructive) {
          model.run { try await $0.deleteFolder(folder.id) }
          deleting = nil
        }
      }
    } message: {
      Text("其中 \(affectedBooks) 本书将移至“未归类”，进度和笔记会保留。")
    }
    .refreshable {
      do { try await model.reload() } catch { model.message = error.localizedDescription }
    }
  }

  // 书架行保持系统导航行为，管理操作同时提供菜单与侧滑入口。
  private func folderRow(_ folder: LibraryFolder) -> some View {
    Group {
      if editing {
        Button { metadata = .folder(folder) } label: {
          HStack { folderLabel(folder); Spacer(); Image(systemName: "pencil").foregroundStyle(.blue) }
        }.buttonStyle(.plain)
      } else {
        NavigationLink { LibraryView(model: model, folderID: folder.id) } label: { folderLabel(folder) }
      }
    }.contextMenu {
      Button("编辑标题与封面", systemImage: "pencil") { metadata = .folder(folder) }
      Button("移动书架", systemImage: "folder") { folderMove = folder }
      Button("删除书架", systemImage: "trash", role: .destructive) { deleting = folder }
    }.swipeActions {
      Button("删除", role: .destructive) { deleting = folder }
      Button("编辑") { metadata = .folder(folder) }.tint(.blue)
    }
  }
  // 书架与书籍使用相同的行内缩略图尺寸，名称与辅助信息沿左侧对齐。
  private func folderLabel(_ folder: LibraryFolder) -> some View {
      HStack(spacing: 12) {
        folderCover(folder, framed: true).frame(width: 46, height: 69)
        VStack(alignment: .leading, spacing: 3) {
          Text(folder.title).font(.headline)
          Text("\(model.books.filter{$0.folderID==folder.id}.count) 本书").font(.caption)
            .foregroundStyle(.secondary)
        }
      }
  }
  // 图书行保留阅读进度与多选入口，缩略图和书架行统一为 2:3。
  private func bookRow(_ book: Book) -> some View {
    HStack(spacing: 12) {
    Button {
      selectOrOpen(book)
    } label: {
      HStack(spacing: 12) {
        if editing {
          Image(systemName: selected.contains(book.id) ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(.blue)
        }
        CoverView(url: model.fileURL(book.effectiveCover)).frame(width: 46, height: 69)
        VStack(alignment: .leading, spacing: 5) {
          Text(book.title).font(.headline).lineLimit(2).foregroundStyle(.primary)
          Text(
            !query.isEmpty
              ? model.folderPath(book.folderID)
              : book.author.isEmpty ? book.format.label : book.author
          ).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          if book.progress > 0 {
            HStack {
              ProgressView(value: book.progress).tint(.blue).frame(maxWidth: 135)
              Text("\(ReadingProgress.percent(book.progress))%").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
          }
        }
        Spacer()
        if book.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption) }
        if !editing {
          Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
      }.padding(.vertical, 4).contentShape(Rectangle())
    }.buttonStyle(.plain)
      if editing {
        Button { metadata = .book(book) } label: { Image(systemName: "pencil").frame(width: 32, height: 40) }
          .buttonStyle(.borderless).accessibilityLabel("编辑\(book.title)")
      }
    }
      .contextMenu { bookMenu(book) }
      .swipeActions {
        Button("删除", role: .destructive) { model.trash([book.id]) }
        Button("编辑") { metadata = .book(book) }.tint(.blue)
      }
  }
  // 两种书架视图共用选择行为，编辑模式不会误打开正文。
  private func selectOrOpen(_ book: Book) {
    if editing {
      if !selected.insert(book.id).inserted { selected.remove(book.id) }
    } else { model.open(book) }
  }
  @ViewBuilder private func bookMenu(_ book: Book) -> some View {
    Button(book.format == .web ? "编辑标题、封面与链接" : "编辑标题与封面", systemImage: "pencil") { metadata = .book(book) }
    // 只修改选中的状态字段，缓存与阅读进度可在书架菜单打开期间继续更新。
    Button(book.isFavorite ? "取消收藏" : "收藏", systemImage: "heart") {
      model.run { try await $0.batchEditBooks([book.id], favorite: !book.isFavorite) }
    }
    Button(book.isFinished ? "标为未读" : "标为已读", systemImage: "checkmark.circle") {
      model.run { try await $0.batchEditBooks([book.id], finished: !book.isFinished) }
    }
    Button("移动到书架", systemImage: "folder") {
      selected = [book.id]
      moving = true
    }
    if let url = book.webURL {
      ShareLink(item: url) { Label("分享网页链接", systemImage: "square.and.arrow.up") }
      if book.hasWebReadingCopy, let reading = model.fileURL(book.readingPath) {
        ShareLink(item: reading) { Label("导出正文 EPUB", systemImage: "doc.richtext") }
      }
    } else if let original = model.fileURL(book.originalPath) {
      ShareLink(item: original) { Label("导出原书", systemImage: "square.and.arrow.up") }
    }
    Button("导出阅读笔记", systemImage: "quote.bubble") {
      model.exportNotes(bookID: book.id, markdown: true)
    }
    Button("删除书籍", systemImage: "trash", role: .destructive) { model.trash([book.id]) }
  }
  private var filterRow: some View {
    // 单一菜单替代整行分段栏，保留四种范围，窄屏和大字号也能完整显示。
    HStack {
      Menu {
        Picker("书架范围", selection: $filter) {
          Label("书架", systemImage: "folder").tag(0)
          Label("最近", systemImage: "clock").tag(1)
          Label("收藏", systemImage: "heart").tag(2)
          Label("已读", systemImage: "checkmark.circle").tag(3)
        }
      } label: {
        HStack(spacing: 8) {
          Label(["书架", "最近", "收藏", "已读"][filter],
                systemImage: ["folder", "clock", "heart", "checkmark.circle"][filter])
          Image(systemName: "chevron.down").font(.caption.weight(.bold))
        }.font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 11)
          .mioGlass(radius: 22, interactive: true)
      }.buttonStyle(FluidButtonStyle()).accessibilityLabel("书架范围，下拉选择")
      Spacer()
      Text("\(visible.count) 本").font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }.padding(.vertical, 6).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
  }
  // 布局和排序由同一偏好对象写入数据库，目录视图之间立即同步。
  private func preference<T>(_ path: WritableKeyPath<ReaderPreferences, T>) -> Binding<T> {
    Binding(get: { model.preferences[keyPath: path] }, set: { next in
      var prefs = model.preferences
      prefs[keyPath: path] = next
      withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) { model.changePreferences(prefs) }
    })
  }
  // 两类封面共用列宽与纵横比，书架底板和书籍封面随屏幕宽度同步变化。
  private let coverAspectRatio: CGFloat = 2.0 / 3.0
  private var coverColumns: [GridItem] {
    [GridItem(.adaptive(minimum: 110, maximum: 170), spacing: 20)]
  }
  // 书架仅在封面模式中排列为卡片，与下方书籍使用完全相同的列配置。
  private var shelfCovers: some View {
    LazyVGrid(columns: coverColumns, alignment: .leading, spacing: 24) {
      ForEach(children) { folderTile($0) }
    }
  }
  // 两种布局共用封面内容；四宫格实时跟随书籍封面、所属书架及排序变化。
  @ViewBuilder private func folderCover(_ folder: LibraryFolder, framed: Bool = false) -> some View {
    if model.preferences.shelfCoverStyle == .mosaic {
      let covers = ShelfCoverSelection.slots(folderID: folder.id, books: model.books,
                                             sort: model.preferences.bookSort)
      ShelfMosaicCover(urls: covers.map { model.fileURL($0) })
        .modifier(ShelfCoverFrame(enabled: framed))
    } else {
      // 切回单张封面时仍读取原文件，不修改或删除已设置的书架封面。
      CoverView(url: model.fileURL(folder.coverPath), folder: framed, placeholder: "books.vertical.fill")
    }
  }
  // 卡片仍提供进入书架、编辑和长按管理，玻璃底板用于区分书架与图书。
  private func folderTile(_ folder: LibraryFolder) -> some View {
    Group {
      if editing {
        Button { metadata = .folder(folder) } label: { folderTileLabel(folder) }
      } else {
        NavigationLink { LibraryView(model: model, folderID: folder.id) } label: { folderTileLabel(folder) }
      }
    }.buttonStyle(FluidButtonStyle()).contextMenu {
      Button("编辑标题与封面", systemImage: "pencil") { metadata = .folder(folder) }
      Button("移动书架", systemImage: "books.vertical") { folderMove = folder }
      Button("删除书架", systemImage: "trash", role: .destructive) { deleting = folder }
    }
  }
  // 底板本身保持 2:3；标题和本数放在底板外，不再参与其高度计算。
  private func folderTileLabel(_ folder: LibraryFolder) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Color.clear.aspectRatio(coverAspectRatio, contentMode: .fit)
        .overlay {
          // 封面继续占底板宽度的 80% 并居中，两者共享 2:3 比例。
          GeometryReader { geometry in
            folderCover(folder)
              .compositingGroup().shadow(color: .black.opacity(0.08), radius: 3, y: 2)
              .aspectRatio(coverAspectRatio, contentMode: .fit).frame(width: geometry.size.width * 0.8)
              .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
          }
        }
        .mioFrostedCard(radius: 30)
        .overlay(alignment: .topTrailing) {
          if editing { Image(systemName: "pencil.circle.fill").foregroundStyle(.blue).padding(5) }
        }
      shelfTitle(folder)
      shelfCount(folder)
    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(folder.title)，\(model.books.filter { $0.folderID == folder.id }.count) 本")
  }
  // 文字沿用原字号与缩进，较长书架名称保持单行截断。
  private func shelfTitle(_ folder: LibraryFolder) -> some View {
    Text(folder.title).font(.title2.weight(.bold)).foregroundStyle(.primary)
      .lineLimit(1).minimumScaleFactor(0.85).padding(.leading, 4)
  }
  private func shelfCount(_ folder: LibraryFolder) -> some View {
    Text("\(model.books.filter { $0.folderID == folder.id }.count) 本")
      .font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
  }
  // 封面模式统一使用纵向大封面，移除紧凑网格的尺寸与背景分支。
  private var coversView: some View {
    ScrollView {
      // 外层只排列筛选和网格，网格自行延迟创建卡片，避免两层延迟布局共同估算尾部高度。
      VStack(alignment: .leading, spacing: 20) {
        if folderID == nil && query.isEmpty { filterRow }
        if query.isEmpty && filter == 0 {
          shelfCovers
        }
        LazyVGrid(
          columns: coverColumns,
          alignment: .leading, spacing: 24
        ) {
          ForEach(visible) { book in
            VStack(alignment: .leading, spacing: 6) {
            Button {
              selectOrOpen(book)
            } label: {
              VStack(alignment: .leading, spacing: 8) {
                CoverView(url: model.fileURL(book.effectiveCover)).aspectRatio(coverAspectRatio, contentMode: .fit)
                  .frame(maxWidth: .infinity)
                  .shadow(color: .black.opacity(0.09), radius: 5, y: 3)
                  .overlay(alignment: .topTrailing) {
                    if editing {
                      Image(systemName: selected.contains(book.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title2).foregroundStyle(.blue).padding(5).background(.regularMaterial, in: Circle()).padding(5)
                    }
                  }
                Text(book.title).font(.subheadline.weight(.medium))
                  .foregroundStyle(.primary).lineLimit(2)
                Text(book.progress > 0 ? "\(book.format.label) · \(ReadingProgress.percent(book.progress))%" : book.format.label)
                  .font(.caption2).foregroundStyle(.secondary)
              }
            }.buttonStyle(FluidButtonStyle()).contextMenu { bookMenu(book) }
              if editing {
                Button("编辑标题与封面", systemImage: "pencil") { metadata = .book(book) }
                  .font(.caption2).buttonStyle(.borderless)
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }.padding(16)
    }.background(Color(.systemGroupedBackground))
  }
  private func descendants(_ id: UUID) -> Set<UUID> {
    var ids: Set<UUID> = [id]
    var changed = true
    while changed {
      changed = false
      for folder in model.folders where folder.parentID.map(ids.contains) == true {
        if ids.insert(folder.id).inserted { changed = true }
      }
    }
    return ids
  }
  private var affectedBooks: Int {
    guard let folder = deleting else { return 0 }
    let ids = descendants(folder.id)
    return model.books.filter { $0.folderID.map(ids.contains) == true }.count
  }
}

// 缩略图按目标像素解码并缓存，避免列表滚动时解码原始大图。
actor ThumbnailCache {
  static let shared = ThumbnailCache()
  private let cache = NSCache<NSString, UIImage>()
  init() { cache.totalCostLimit = 48 * 1024 * 1024 }
  func image(_ url: URL) -> UIImage? {
    if let value = cache.object(forKey: url.path as NSString) { return value }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let cg = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          // 两列大封面在三倍屏上需要更高像素，缓存仍受上方 48 MB 总量限制。
          kCGImageSourceThumbnailMaxPixelSize: 720,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    else { return nil }
    let image = UIImage(cgImage: cg)
    cache.setObject(image, forKey: url.path as NSString, cost: cg.bytesPerRow * cg.height)
    return image
  }
}
struct CoverView: View {
  let url: URL?
  var folder = false
  var preview: UIImage?
  var placeholder: String?
  @State private var image: UIImage?
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 5).fill(
        folder ? Color.blue.opacity(0.09) : Color(.tertiarySystemGroupedBackground))
      if let image = preview ?? image {
        Image(uiImage: image).resizable().scaledToFill()
      } else {
        Image(systemName: placeholder ?? (folder ? "books.vertical.fill" : "book.closed.fill")).font(
          folder ? .title2 : .largeTitle
        ).foregroundStyle(folder ? Color.blue : Color.secondary.opacity(0.5))
      }
    }.clipped().clipShape(RoundedRectangle(cornerRadius: 5))
      .modifier(ShelfCoverFrame(enabled: folder))
      .task(id: url) {
        image = nil
        if let url { image = await ThumbnailCache.shared.image(url) }
      }
      .accessibilityHidden(true)
  }
}

// 玻璃只包住封面外侧的 3 点细边，不降低封面图像本身的不透明度。
private struct ShelfCoverFrame: ViewModifier {
  let enabled: Bool
  func body(content: Content) -> some View {
    if enabled { content.padding(3).mioGlass(radius: 10) }
    else { content }
  }
}
