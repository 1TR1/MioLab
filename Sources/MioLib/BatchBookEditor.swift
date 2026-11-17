import MioLibCore
import SwiftUI

// 三态选项区分“不修改”和明确设为是／否，避免把混合选择中的原状态覆盖掉。
private enum BatchChange: Int { case unchanged, yes, no
  var value: Bool? { self == .unchanged ? nil : self == .yes }
}

struct BatchBookEditor: View {
  @ObservedObject var model: AppModel
  let ids: Set<UUID>
  let onApply: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var favorite = BatchChange.unchanged
  @State private var finished = BatchChange.unchanged
  @State private var move = false
  @State private var folderID: UUID?
  @State private var choosingFolder = false
  @State private var saving = false
  @State private var error: String?
  private var changed: Bool { favorite != .unchanged || finished != .unchanged || move }
  var body: some View {
    NavigationStack {
      Form {
        Section("所选 \(ids.count) 本书") {
          Picker("收藏", selection: $favorite) {
            Text("保持原样").tag(BatchChange.unchanged)
            Text("加入收藏").tag(BatchChange.yes)
            Text("取消收藏").tag(BatchChange.no)
          }
          Picker("阅读状态", selection: $finished) {
            Text("保持原样").tag(BatchChange.unchanged)
            Text("标为已读").tag(BatchChange.yes)
            Text("标为未读").tag(BatchChange.no)
          }
          Toggle("移动到书架", isOn: $move)
          if move {
            Button(model.folderPath(folderID)) { choosingFolder = true }
          }
        }
        Section { Text("阅读位置会保留；只应用在此处选定的修改。").font(.footnote).foregroundStyle(.secondary) }
      }
      .disabled(saving)
      .navigationTitle("批量编辑").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
        ToolbarItem(placement: .confirmationAction) {
          Button("应用") { apply() }.disabled(!changed || saving || model.maintenance || ids.isEmpty)
        }
      }
      .overlay { if saving { ProgressView("正在保存…") } }
      .interactiveDismissDisabled(saving)
      .sheet(isPresented: $choosingFolder) {
        FolderPicker(model: model, title: "选择批量移动位置") { folderID = $0 }
      }
      .alert("无法批量编辑", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
        Button("好", role: .cancel) { error = nil }
      } message: { Text(error ?? "") }
    }
  }

  // 所有选定属性一次提交，失败后保留当前选择和表单，便于修正目标位置。
  private func apply() {
    guard let repository = model.repository else { return }
    saving = true
    Task {
      do {
        try await repository.batchEditBooks(ids, favorite: favorite.value, finished: finished.value,
          move: move, folderID: folderID)
        try await model.reload()
        onApply()
        dismiss()
      } catch { self.error = error.localizedDescription; saving = false }
    }
  }
}
