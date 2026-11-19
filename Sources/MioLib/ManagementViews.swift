import ImageIO
import MioLibCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// 元数据编辑统一处理书籍和书架，所有修改在保存后一次性提交。
enum MetadataTarget: Identifiable {
  case book(Book)
  case folder(LibraryFolder)
  var id: UUID {
    switch self {
    case .book(let item): item.id
    case .folder(let item): item.id
    }
  }
  var title: String {
    switch self {
    case .book(let item): item.title
    case .folder(let item): item.title
    }
  }
  var cover: String? {
    switch self {
    case .book(let item): item.effectiveCover
    case .folder(let item): item.coverPath
    }
  }
  var isFolder: Bool {
    if case .folder = self { return true }
    return false
  }
  // 恢复默认时，书籍预览原文件封面，书架预览系统书架图标。
  var defaultCover: String? {
    if case .book(let item) = self { return item.coverPath }
    return nil
  }
}
struct PickedCover: Identifiable {
  let id = UUID()
  let image: UIImage
}
struct MetadataEditor: View {
  @ObservedObject var model: AppModel
  let target: MetadataTarget
  @Environment(\.dismiss) private var dismiss
  @State private var title: String
  // 网页链接沿用普通书籍编辑表单，与标题及封面一起提交。
  @State private var webAddress: String
  @State private var error: String?
  @State private var photo: PhotosPickerItem?
  @State private var filePicker = false
  @State private var crop: PickedCover?
  @State private var coverData: Data?
  @State private var resetCover = false
  @State private var saving = false
  @State private var folderBooks = false
  @State private var bookPages = false
  @State private var selectedCoverURL: URL?
  @State private var selectedPageImage: UIImage?
  init(model: AppModel, target: MetadataTarget) {
    self.model = model
    self.target = target
    _title = State(initialValue: target.title)
    if case .book(let book) = target { _webAddress = State(initialValue: book.webURL?.absoluteString ?? "") }
    else { _webAddress = State(initialValue: "") }
  }
  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack {
            Spacer()
            CoverView(url: model.fileURL(resetCover ? target.defaultCover : target.cover),
                      folder: target.isFolder, preview: coverData.flatMap { UIImage(data: $0) })
              .frame(width: 112, height: 168)
            Spacer()
          }.listRowBackground(Color.clear)
          PhotosPicker(selection: $photo, matching: .images) {
            Label("从照片选择封面", systemImage: "photo")
          }
          Button("从图片文件选择", systemImage: "folder") { filePicker = true }
          if case .folder = target {
            Button("从书架中的书籍选择", systemImage: "books.vertical") { folderBooks = true }
          }
          if case .book(let book) = target {
            Button("从书页选择封面", systemImage: "doc.richtext") { bookPages = true }
              .disabled(book.format == .web && !book.hasWebReadingCopy)
            if book.format == .web && !book.hasWebReadingCopy {
              Text("首次进入阅读模式并提取正文后，可从书页选择封面。").font(.caption).foregroundStyle(.secondary)
            }
          }
          Button("恢复默认封面", systemImage: "arrow.counterclockwise") {
            coverData = nil
            resetCover = true
          }
        }
        Section(target.isFolder ? "书架名称" : "书籍标题") {
          TextField("名称", text: $title).textInputAutocapitalization(.never)
          if case .book(let book) = target { Button("恢复原标题") { title = book.originalTitle } }
        }
        // 改链会使原来的正文定位失效，保存前说明对进度与笔记的影响。
        if case .book(let book) = target, book.format == .web {
          Section {
            TextField("https://example.com", text: $webAddress, axis: .vertical)
              .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
          } header: { Text("网页链接") } footer: {
            Text("修改链接后需重新提取正文，阅读进度会重置。已有笔记文字保留，旧定位会清除；网址收藏中的链接独立保存。")
          }
        }
        if let error { Section { Text(error).foregroundStyle(.red) } }
        Section { Text("标题和封面保存在书库中，并随完整备份保存。").font(.footnote).foregroundStyle(.secondary) }
      }.navigationTitle(target.isFolder ? "编辑书架" : "编辑书籍").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
          ToolbarItem(placement: .confirmationAction) {
            Button("保存") { save() }.disabled(
              title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
          }
        }
        .overlay { if saving { ProgressView() } }
    }.interactiveDismissDisabled(saving)
    .onChange(of: photo) { _, item in
      Task {
        do {
          if let data = try await item?.loadTransferable(type: Data.self) { try loadImage(data) }
        } catch { model.message = error.localizedDescription }
      }
    }
    .fileImporter(isPresented: $filePicker, allowedContentTypes: [.image]) { result in
      do {
        let url = try result.get()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try loadImage(Data(contentsOf: url))
      } catch { model.message = error.localizedDescription }
    }
    .fullScreenCover(item: $crop) { picked in
      CoverCropView(image: picked.image, aspect: 2 / 3) { data in
        coverData = data
        resetCover = false
      }
    }
    // 来源选择关闭后再打开裁切页，避免在同一个呈现层同时弹出两个面板。
    .sheet(isPresented: $folderBooks, onDismiss: loadSelectedBookCover) {
      FolderBookCoverPicker(model: model, folderID: target.id) { selectedCoverURL = $0 }
    }
    .fullScreenCover(isPresented: $bookPages, onDismiss: {
      if let image = selectedPageImage { selectedPageImage = nil; crop = PickedCover(image: image) }
    }) {
      if case .book(let book) = target {
        BookPageCoverPicker(model: model, book: book) { selectedPageImage = $0 }
      }
    }
  }
  private func loadSelectedBookCover() {
    guard let url = selectedCoverURL else { return }
    selectedCoverURL = nil
    Task {
      do {
        let data = try await Task.detached(priority: .userInitiated) {
          let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
          guard size <= 20 * 1024 * 1024 else { throw LibraryError.message("封面图片过大") }
          return try Data(contentsOf: url)
        }.value
        try loadImage(data)
      } catch { model.message = error.localizedDescription }
    }
  }
  private func loadImage(_ data: Data) throws {
    guard data.count <= 20 * 1024 * 1024,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 1800,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    else { throw LibraryError.message("请选择有效且小于 20 MB 的图片") }
    crop = PickedCover(image: UIImage(cgImage: image))
  }
  private func save() {
    guard let repository = model.repository else { return }
    saving = true
    Task {
      do {
        switch target {
        case .book(let original):
          try await repository.updateBookMetadata(original.id, title: title, coverData: coverData,
            resetCover: resetCover, webAddress: original.format == .web ? webAddress : nil)
        case .folder(let original):
          var folder = try await repository.folders().first { $0.id == original.id } ?? original
          let path = try await coverData.asyncMap { try await repository.storeCover($0) }
          folder.title = title
          if let path { folder.coverPath = path } else if resetCover { folder.coverPath = nil }
          try await repository.saveFolder(folder)
        }
        try await model.reload()
        dismiss()
      } catch {
        self.error = error.localizedDescription
        saving = false
      }
    }
  }
}

// 裁切窗口固定比例，图片缩放与拖动受边界约束，导出限制为 800 像素宽。
struct CoverCropView: View {
  let image: UIImage
  let aspect: CGFloat
  let onSave: (Data) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var zoom: CGFloat = 1
  @State private var lastZoom: CGFloat = 1
  @State private var offset = CGSize.zero
  @State private var lastOffset = CGSize.zero
  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
        // 横屏和 iPad 分屏也为说明及保存按钮留出空间，避免裁切区域挤出屏幕。
        let spacing: CGFloat = geometry.size.height < 450 ? 12 : 24
        let availableHeight = max(80, geometry.size.height - spacing * 4 - 88)
        let width = max(40, min(geometry.size.width - 40, 340, availableHeight * aspect))
        let height = width / aspect
        let base = max(width / image.size.width, height / image.size.height)
        VStack(spacing: spacing) {
          Spacer()
          ZStack {
            Color.black
            Image(uiImage: image).resizable().frame(
              width: image.size.width * base * zoom, height: image.size.height * base * zoom
            ).offset(offset)
          }.frame(width: width, height: height).clipped().overlay(
            Rectangle().stroke(.white.opacity(0.8), lineWidth: 1)
          )
          .gesture(
            DragGesture().onChanged { value in
              offset = bounded(
                CGSize(
                  width: lastOffset.width + value.translation.width,
                  height: lastOffset.height + value.translation.height), width: width,
                height: height, base: base)
            }.onEnded { _ in lastOffset = offset }
          )
          .simultaneousGesture(
            MagnifyGesture().onChanged { value in
              zoom = min(4, max(1, lastZoom * value.magnification))
              offset = bounded(offset, width: width, height: height, base: base)
            }.onEnded { _ in
              lastZoom = zoom
              lastOffset = offset
            })
          Text("拖动调整位置，双指缩放").font(.footnote).foregroundStyle(.secondary)
          Spacer()
          Button("使用此封面") {
            let ratio: CGFloat = 800 / width
            // 固定输出像素尺寸，避免高倍率屏幕把封面生成到 2400 像素而额外占用内存。
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 800 / aspect), format: format)
            let result = renderer.image { context in
              UIColor.white.setFill()
              context.fill(CGRect(x: 0, y: 0, width: 800, height: 800 / aspect))
              let size = CGSize(
                width: image.size.width * base * zoom * ratio,
                height: image.size.height * base * zoom * ratio)
              image.draw(
                in: CGRect(
                  x: (800 - size.width) / 2 + offset.width * ratio,
                  y: (800 / aspect - size.height) / 2 + offset.height * ratio, width: size.width,
                  height: size.height))
            }
            if let data = result.jpegData(compressionQuality: 0.88) {
              onSave(data)
              dismiss()
            }
          }.buttonStyle(.borderedProminent).padding(.bottom, 24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }.navigationTitle("裁切封面").navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
      }
    }
  }
  private func bounded(_ value: CGSize, width: CGFloat, height: CGFloat, base: CGFloat) -> CGSize {
    let x = max(0, (image.size.width * base * zoom - width) / 2)
    let y = max(0, (image.size.height * base * zoom - height) / 2)
    return CGSize(width: min(x, max(-x, value.width)), height: min(y, max(-y, value.height)))
  }
}

// 书架选择器保留完整路径，并从选择列表排除当前书架的全部后代。
struct FolderPicker: View {
  @ObservedObject var model: AppModel
  let title: String
  var excluding: Set<UUID> = []
  let onSelect: (UUID?) -> Void
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      List {
        Button {
          onSelect(nil)
          dismiss()
        } label: {
          Label("根目录 / 未归类", systemImage: "tray")
        }
        ForEach(
          model.folders.filter { !excluding.contains($0.id) }.sorted {
            model.folderPath($0.id) < model.folderPath($1.id)
          }
        ) { folder in
          Button {
            onSelect(folder.id)
            dismiss()
          } label: {
            Label(model.folderPath(folder.id), systemImage: "folder")
          }
        }
      }.navigationTitle(title).navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
      }
    }
  }
}

// USB 页只展示已传入的书籍文件；选择目标书架后一次性加入导入队列。
struct USBImportView: View {
  @ObservedObject var model: AppModel
  let initialFolder: UUID?
  @Environment(\.dismiss) private var dismiss
  @State private var files: [URL] = []
  @State private var selection: Set<URL> = []
  @State private var folderID: UUID?
  @State private var selectingFolder = false
  // Calibre 的专用传书目录自动接收，其他 USB 文件仍由用户选择后导入。
  @AppStorage("calibre.usbAutomatic") private var calibreAutomatic = true
  @AppStorage("calibre.usbFolder") private var calibreFolder = ""
  @State private var selectingCalibreFolder = false
  var body: some View {
    NavigationStack {
      List {
        Section("Calibre USB") {
          Text("在电脑 Calibre 选中书籍，点击“发送到 MioLib（USB）”。传输完成后，打开 MioLib 即可自动入库，无需连接 Wi-Fi。")
            .font(.subheadline)
          Toggle("自动接收 Calibre USB 传书", isOn: $calibreAutomatic)
          Button("自动导入到：\(model.folderPath(UUID(uuidString: calibreFolder)))") {
            selectingCalibreFolder = true
          }
          Button("立即接收") { Task { await model.receiveCalibreUSB() } }
            .disabled(!calibreAutomatic || model.maintenance)
        }
        Section {
          Text(
            "用数据线连接电脑。在 Windows 的 Apple Devices 或 Mac 的 Finder 中，选择设备 → 文件 → MioLib，将多本书复制到此应用。等待复制完成，再刷新列表。"
          )
          Button("刷新传入文件", systemImage: "arrow.clockwise") { Task { await refresh() } }
          Button("导入到：\(model.folderPath(folderID))") { selectingFolder = true }
        }.font(.subheadline)
        Section("待导入 · \(files.count) 本") {
          ForEach(files, id: \.self) { url in
            Button {
              if !selection.insert(url).inserted { selection.remove(url) }
            } label: {
              HStack {
                Image(systemName: selection.contains(url) ? "checkmark.circle.fill" : "circle")
                Text(url.lastPathComponent).foregroundStyle(.primary)
              }
            }
          }
          if files.isEmpty { Text("尚未发现书籍文件").foregroundStyle(.secondary) }
        }
      }.navigationTitle("电脑 USB 传书").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("导入 \(selection.count) 本") {
              let urls = files.filter(selection.contains)
              dismiss()
              model.importURLs(urls, folderID: folderID, usb: true)
            }.disabled(selection.isEmpty || model.maintenance)
          }
        }
        .task {
          folderID = initialFolder
          await refresh()
        }
        .sheet(isPresented: $selectingFolder) {
          FolderPicker(model: model, title: "选择导入位置") { folderID = $0 }
        }
        .sheet(isPresented: $selectingCalibreFolder) {
          FolderPicker(model: model, title: "Calibre USB 默认位置") { calibreFolder = $0?.uuidString ?? "" }
        }
    }
  }
  private func refresh() async {
    files = await model.usbFiles()
    selection = Set(files)
  }
}

// 失败记录保留暂存副本；TXT 可指定编码后重新执行同一导入任务。
struct ImportQueueView: View {
  @ObservedObject var model: AppModel
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      List {
        if model.processing { Section { ProgressView("正在导入，其他功能仍可使用") } }
        if model.jobs.isEmpty { ContentUnavailableView("没有导入记录", systemImage: "tray") }
        ForEach(model.jobs) { job in
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(job.state)).foregroundStyle(
              job.state == .failed ? .red : job.state == .completed ? .green : .secondary)
            VStack(alignment: .leading, spacing: 5) {
              Text(job.name).font(.headline)
              Text(job.detail).font(.caption).foregroundStyle(.secondary)
              if job.state == .failed || job.state == .cancelled {
                HStack {
                  Button("重试") { model.retry(job) }.buttonStyle(.bordered)
                  if job.name.lowercased().hasSuffix(".txt") {
                    Menu("更换编码") {
                      ForEach(["UTF-8", "UTF-16LE", "UTF-16BE", "GB18030"], id: \.self) {
                        encoding in Button(encoding) { model.retry(job, encoding: encoding) }
                      }
                    }
                  }
                }.font(.caption)
              }
            }
            Spacer()
          }.padding(.vertical, 4)
        }
      }.navigationTitle("导入记录").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
          ToolbarItem(placement: .topBarTrailing) {
            if model.processing {
              Button("取消导入", role: .destructive) { model.cancelImports() }
            } else {
              Button("清除已完成") { model.run { try await $0.clearCompletedJobs() } }
            }
          }
        }
    }
  }
  private func icon(_ state: ImportState) -> String {
    switch state {
    case .completed: "checkmark.circle.fill"
    case .failed: "exclamationmark.circle.fill"
    case .processing: "arrow.triangle.2.circlepath"
    case .duplicate: "doc.on.doc"
    case .cancelled: "xmark.circle"
    case .queued: "clock"
    }
  }
}

// 笔记列表保留点击回到原文的主操作，修改与导出作为明确的辅助操作。
struct NotesView: View {
  @ObservedObject var model: AppModel
  var bookID: UUID? = nil
  @State private var query = ""
  @State private var editing: Annotation?
  private var notes: [Annotation] {
    model.notes.filter {
      (bookID == nil || $0.bookID == bookID)
        && (query.isEmpty || $0.note.localizedCaseInsensitiveContains(query)
          || $0.quote.localizedCaseInsensitiveContains(query))
    }
  }
  var body: some View {
    List {
      ForEach(notes) { note in
        Button {
          if let book = model.books.first(where: { $0.id == note.bookID }) {
            model.open(book, annotation: note)
          }
        } label: {
          VStack(alignment: .leading, spacing: 8) {
            Label(
              model.books.first(where: { $0.id == note.bookID })?.title ?? "书籍",
              systemImage: note.kind == .bookmark ? "bookmark.fill" : "quote.opening"
            ).font(.caption).foregroundStyle(.secondary)
            if !note.quote.isEmpty { Text(note.quote).lineLimit(4).foregroundStyle(.primary) }
            if !note.note.isEmpty { Text(note.note).font(.subheadline).foregroundStyle(.primary) }
            Text(note.chapter).font(.caption2).foregroundStyle(.secondary)
          }.padding(.vertical, 5)
        }.contextMenu {
          Button("编辑批注") { editing = note }
          Button("删除", role: .destructive) { model.run { try await $0.deleteAnnotation(note.id) } }
        }.swipeActions {
          Button("删除", role: .destructive) { model.run { try await $0.deleteAnnotation(note.id) } }
        }
      }
    }.overlay {
      if notes.isEmpty {
        ContentUnavailableView(
          "还没有阅读笔记", systemImage: "quote.bubble", description: Text("阅读时选中文字，添加高亮或批注。"))
      }
    }
    .navigationTitle("笔记").searchable(text: $query, prompt: "搜索摘录和批注")
    .toolbar {
      Menu {
        Button("导出 Markdown") { model.exportNotes(bookID: bookID, markdown: true) }
        Button("导出 JSON") { model.exportNotes(bookID: bookID, markdown: false) }
      } label: {
        Image(systemName: "square.and.arrow.up")
      }
    }
    .sheet(item: $editing) {
      AnnotationEditor(annotation: $0) { note in model.run { try await $0.saveAnnotation(note) } }
    }
  }
}
struct AnnotationEditor: View {
  let annotation: Annotation
  let onSave: (Annotation) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var note: String
  @State private var color: String
  init(annotation: Annotation, onSave: @escaping (Annotation) -> Void) {
    self.annotation = annotation
    self.onSave = onSave
    _note = State(initialValue: annotation.note)
    _color = State(initialValue: annotation.color)
  }
  var body: some View {
    NavigationStack {
      Form {
        if !annotation.quote.isEmpty {
          Section("原文") { Text(annotation.quote).font(.subheadline).foregroundStyle(.secondary) }
        }
        Section("批注") { TextEditor(text: $note).frame(minHeight: 160) }
        if annotation.kind != .bookmark {
          Section("高亮颜色") {
            Picker("颜色", selection: $color) {
              Text("黄色").tag("yellow")
              Text("绿色").tag("green")
              Text("蓝色").tag("blue")
              Text("粉色").tag("pink")
            }.pickerStyle(.segmented)
          }
        }
      }.navigationTitle("阅读批注").navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            var next = annotation
            next.note = note
            next.color = color
            onSave(next)
            dismiss()
          }
        }
      }
    }
  }
}

// 我的整合阅读记录、阅读偏好、数据管理与关于，笔记仍可单独搜索和回到原文。
struct MyView: View {
  @ObservedObject var model: AppModel
  @Environment(\.interfaceLayoutScale) private var scale
  @State private var readingSettings = false
  @State private var interfaceSettings = false
  var body: some View {
    RoundedSettingsPage {
      RoundedSettingsCard {
        // 个人入口采用参考图中的大头像与双行信息，整行均可点击进入。
        NavigationLink { PersonalSpaceView(model: model) } label: {
          HStack(spacing: 16 * scale) {
            ProfileAvatarView(url: model.fileURL(model.preferences.profileAvatarPath), size: 62 * scale)
            VStack(alignment: .leading, spacing: 8 * scale) {
              Text("我的阅读空间").font(.title2.weight(.semibold))
              Text("\(model.preferences.profileName) · 个人资料与备份")
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
          }.padding(18 * scale).frame(minHeight: 110 * scale).foregroundStyle(.primary).contentShape(Rectangle())
        }.buttonStyle(FluidButtonStyle())
        Divider().padding(.leading, 96 * scale).padding(.trailing, 18 * scale)
        HStack {
          Text("我的藏书").foregroundStyle(.primary)
          Spacer()
          Text("\(model.books.count) 本 · \(model.folders.count) 个书架").foregroundStyle(.secondary)
        }.font(.body).padding(.horizontal, 20 * scale).frame(minHeight: max(44, 56 * scale))
      }
      RoundedSettingsGroup("阅读记录") {
        // 网页收藏与书内书签分别管理，两个入口共用同一个收藏列表。
        NavigationLink { WebLibraryView(model: model) } label: {
          RoundedSettingsRow(title: "网页阅读与收藏", symbol: "globe", color: .blue,
                             value: "\(model.webBookmarks.count)")
        }.buttonStyle(FluidButtonStyle())
        RoundedSettingsDivider()
        NavigationLink { NotesView(model: model) } label: {
          RoundedSettingsRow(title: "阅读笔记与书签", symbol: "quote.bubble.fill", color: .orange,
                             value: "\(model.notes.count)")
        }.buttonStyle(FluidButtonStyle())
        RoundedSettingsDivider()
        RoundedSettingsRow(title: "已读书籍", symbol: "checkmark", color: .green,
                           value: "\(model.books.filter(\.isFinished).count) 本", disclosure: false)
        RoundedSettingsDivider()
        RoundedSettingsRow(title: "收藏书籍", symbol: "heart.fill", color: .pink,
                           value: "\(model.books.filter(\.isFavorite).count) 本", disclosure: false)
      }
      RoundedSettingsGroup("阅读偏好") {
        Menu {
          Picker("主题", selection: preference(\.theme)) {
            ForEach(ReaderTheme.allCases, id: \.self) { Text($0.label).tag($0) }
          }
        } label: {
          RoundedSettingsRow(title: "主题", symbol: "paintpalette.fill", color: .indigo, value: model.preferences.theme.label)
        }.buttonStyle(FluidButtonStyle())
        RoundedSettingsDivider()
        Button { interfaceSettings = true } label: {
          RoundedSettingsRow(title: "界面字体", symbol: "textformat", value: model.preferences.interfaceTextSize.label)
        }.buttonStyle(FluidButtonStyle())
        RoundedSettingsDivider()
        Button { readingSettings = true } label: {
          RoundedSettingsRow(title: "阅读字体与排版", symbol: "textformat.size")
        }.buttonStyle(FluidButtonStyle())
        // 与书内阅读设置共用注释偏好，未打开书时也能切换。
        RoundedSettingsDivider()
        Menu {
          Picker("注释链接", selection: preference(\.footnoteMode)) {
            ForEach(ReaderFootnoteMode.allCases, id: \.self) { Text($0.label).tag($0) }
          }
        } label: {
          RoundedSettingsRow(title: "注释链接", symbol: "text.bubble", value: model.preferences.footnoteMode.label)
        }.buttonStyle(FluidButtonStyle())
        RoundedSettingsDivider()
        Menu {
          Picker("书架布局", selection: preference(\.shelfLayout)) {
            ForEach(ShelfLayout.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
          }
        } label: {
          RoundedSettingsRow(title: "书架布局", symbol: "square.grid.2x2.fill", value: model.preferences.shelfLayout.label)
        }.buttonStyle(FluidButtonStyle())
        // 与书架右上角菜单共用同一偏好，支持单张封面和四宫格互相切换。
        RoundedSettingsDivider()
        Menu {
          Picker("书架封面", selection: preference(\.shelfCoverStyle)) {
            ForEach(ShelfCoverStyle.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
          }
        } label: {
          RoundedSettingsRow(title: "书架封面", symbol: "square.grid.2x2", value: model.preferences.shelfCoverStyle.label)
        }.buttonStyle(FluidButtonStyle())
        RoundedSettingsDivider()
        Menu {
          Picker("书籍排序", selection: preference(\.bookSort)) {
            ForEach(BookSort.allCases, id: \.self) { Text($0.label).tag($0) }
          }
        } label: {
          RoundedSettingsRow(title: "书籍排序", symbol: "arrow.up.arrow.down", color: .orange, value: model.preferences.bookSort.label)
        }.buttonStyle(FluidButtonStyle())
      }
      RoundedSettingsGroup("数据管理") {
        // 网页书离线卷与普通书的源文件分开管理。
        NavigationLink { WebCacheSettingsView(model: model) } label: {
          RoundedSettingsRow(title: "网页书籍缓存", symbol: "arrow.down.circle", color: .blue)
        }.buttonStyle(FluidButtonStyle())
      }
      RoundedSettingsGroup("关于 MioLib") {
        RoundedSettingsRow(title: "版本", symbol: "info", color: .gray,
                           value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—", disclosure: false)
        RoundedSettingsDivider()
        NavigationLink {
          ScrollView { Text(licenseText).font(.caption.monospaced()).padding() }.navigationTitle(
            "开源许可")
        } label: { RoundedSettingsRow(title: "开源组件", symbol: "curlybraces", color: .gray) }
          .buttonStyle(FluidButtonStyle())
      }
      Text("书籍、进度和笔记保存在本机。支持 EPUB、TXT、PDF、无 DRM 的 MOBI 和 AZW3。")
        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
    }.navigationTitle("我的").navigationBarTitleDisplayMode(.large)
      .sheet(isPresented: $readingSettings) { ReaderSettingsView(model: model, isPDF: false) }
      .sheet(isPresented: $interfaceSettings) { InterfaceFontSettingsView(model: model) }
  }
  // 与书架共用偏好写入入口，避免“我的”与右上角菜单出现不同的选择。
  private func preference<T>(_ path: WritableKeyPath<ReaderPreferences, T>) -> Binding<T> {
    Binding(get: { model.preferences[keyPath: path] }, set: { next in
      var prefs = model.preferences
      prefs[keyPath: path] = next
      model.changePreferences(prefs)
    })
  }
  private var licenseText: String {
    guard let url = Bundle.module.url(forResource: "ThirdPartyNotices", withExtension: "txt") else {
      return
        "Readium · BSD-3-Clause\nZIPFoundation · MIT\nlibmobi 0.12 · LGPL-3.0-or-later\nMozilla Readability 0.6.0 · Apache-2.0\n完整许可随源码附带。"
    }
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  }
}

// 可选数据的异步映射避免在没有替换封面时写入额外文件。
extension Optional {
  fileprivate func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
    if let value = self { return try await transform(value) }
    return nil
  }
}
