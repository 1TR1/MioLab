import MioLibCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// 阅读空间承接个人资料和数据管理，备份、恢复继续使用统一的书库维护流程。
struct PersonalSpaceView: View {
  @ObservedObject var model: AppModel
  @Environment(\.interfaceLayoutScale) private var scale
  @State private var editingProfile = false
  @State private var restorePicker = false
  var body: some View {
    RoundedSettingsPage {
      RoundedSettingsGroup("个人资料") {
        Button { editingProfile = true } label: {
          HStack(spacing: 18 * scale) {
            ProfileAvatarView(url: model.fileURL(model.preferences.profileAvatarPath), size: 72 * scale)
            VStack(alignment: .leading, spacing: 7) {
              Text(model.preferences.profileName).font(.title3.weight(.semibold)).foregroundStyle(.primary)
              Text(model.preferences.profileBio.isEmpty ? "填写一句个人简介" : model.preferences.profileBio)
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
              Text("编辑头像与信息").font(.caption).foregroundStyle(.blue)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
          }.padding(20 * scale).frame(minHeight: 124 * scale).contentShape(Rectangle())
        }.buttonStyle(FluidButtonStyle()).disabled(model.maintenance)
      }
      RoundedSettingsGroup("数据管理") {
        Button { model.backup() } label: {
          RoundedSettingsRow(title: "导出完整书库备份", symbol: "externaldrive.fill", color: .orange)
        }.buttonStyle(FluidButtonStyle()).disabled(model.processing || model.maintenance)
        RoundedSettingsDivider()
        Button { restorePicker = true } label: {
          RoundedSettingsRow(title: "从备份恢复书库", symbol: "arrow.clockwise.icloud", color: .blue)
        }.buttonStyle(FluidButtonStyle()).disabled(model.processing || model.maintenance)
        RoundedSettingsDivider()
        Menu {
          Button("Markdown") { model.exportNotes(markdown: true) }
          Button("JSON") { model.exportNotes(markdown: false) }
        } label: { RoundedSettingsRow(title: "导出全部阅读笔记", symbol: "square.and.arrow.up", color: .green) }
          .buttonStyle(FluidButtonStyle())
      }
      RoundedSettingsGroup("我的书库") {
        RoundedSettingsRow(title: "藏书", symbol: "book.closed.fill", value: "\(model.books.count) 本", disclosure: false)
        RoundedSettingsDivider()
        RoundedSettingsRow(title: "书架", symbol: "books.vertical.fill", color: .orange,
                           value: "\(model.folders.count) 个", disclosure: false)
        RoundedSettingsDivider()
        RoundedSettingsRow(title: "笔记与书签", symbol: "quote.bubble.fill", color: .green,
                           value: "\(model.notes.count) 条", disclosure: false)
      }
      Text("个人资料保存在本机，头像和信息会随完整书库备份保存。")
        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
    }.navigationTitle("我的阅读空间").navigationBarTitleDisplayMode(.inline)
      .sheet(isPresented: $editingProfile) { ProfileEditor(model: model) }
      .fileImporter(isPresented: $restorePicker, allowedContentTypes: [.mioBackup, .zip, .data]) { result in
        do { model.pendingBackup = try result.get() }
        catch { model.message = error.localizedDescription }
      }
  }
}

// 头像按屏幕所需像素读取缓存，不直接解码并显示用户选择的原始大照片。
struct ProfileAvatarView: View {
  let url: URL?
  let size: CGFloat
  var preview: UIImage?
  @State private var image: UIImage?
  var body: some View {
    Group {
      if let image = preview ?? image { Image(uiImage: image).resizable().scaledToFill() }
      else {
        Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(.blue.gradient)
      }
    }.frame(width: size, height: size).background(Color.blue.opacity(0.06), in: Circle())
      .clipShape(Circle()).overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
      .accessibilityLabel("个人头像")
      .task(id: url) {
        image = nil
        if let url { image = await ThumbnailCache.shared.image(url) }
      }
  }
}

// 编辑使用草稿，取消不落盘；头像先裁切，确认保存后才替换资料和文件引用。
private struct ProfileEditor: View {
  @ObservedObject var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var bio: String
  @State private var photo: PhotosPickerItem?
  @State private var crop: PickedCover?
  @State private var avatarData: Data?
  @State private var resetAvatar = false
  @State private var saving = false
  @State private var error: String?
  init(model: AppModel) {
    self.model = model
    _name = State(initialValue: model.preferences.profileName)
    _bio = State(initialValue: model.preferences.profileBio)
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("个人头像") {
          HStack {
            Spacer()
            ProfileAvatarView(url: resetAvatar ? nil : model.fileURL(model.preferences.profileAvatarPath), size: 96,
                              preview: avatarData.flatMap { UIImage(data: $0) })
            Spacer()
          }.padding(.vertical, 8)
          PhotosPicker(selection: $photo, matching: .images) { Label("选择头像", systemImage: "photo") }
          Button("恢复默认头像", systemImage: "arrow.counterclockwise") { avatarData = nil; resetAvatar = true; photo = nil }
        }
        Section("个人信息") {
          TextField("昵称", text: $name).textInputAutocapitalization(.never)
          TextField("个人简介", text: $bio, axis: .vertical).lineLimit(3...6)
          Text("昵称 1～40 字，简介最多 300 字。只在本机保存。")
            .font(.footnote).foregroundStyle(.secondary)
        }
      }.disabled(saving).navigationTitle("编辑个人资料").navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") { save() }.disabled(saving || model.maintenance || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }.overlay { if saving { ProgressView("正在保存…") } }
        .onChange(of: photo) { _, item in
          guard let item else { return }
          Task {
            defer { photo = nil }
            do {
              guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data)
              else { throw LibraryError.message("无法读取所选头像") }
              crop = PickedCover(image: image)
            } catch { self.error = error.localizedDescription }
          }
        }
        .fullScreenCover(item: $crop) { picked in
          CoverCropView(image: picked.image, aspect: 1) { data in avatarData = data; resetAvatar = false }
        }
        .alert("无法保存资料", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
          Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }.interactiveDismissDisabled(saving)
  }
  // 先保存可能仍在防抖中的偏好，再让仓库原子更新个人信息，保留最新布局和排序。
  private func save() {
    guard let repository = model.repository else { return }
    saving = true
    Task {
      defer { saving = false }
      do {
        await model.flushPreferences()
        model.preferences = try await repository.updateProfile(name: name, bio: bio, avatarData: avatarData, resetAvatar: resetAvatar)
        dismiss()
      } catch { self.error = error.localizedDescription }
    }
  }
}
