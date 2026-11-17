import MioLibCore
import SwiftUI

// 保存真实系统字号，原生阅读内容恢复到此基准，不继承应用界面的字号偏移。
private struct SystemReadingTypeKey: EnvironmentKey {
  static let defaultValue: DynamicTypeSize = .large
}
private struct InterfaceLayoutScaleKey: EnvironmentKey {
  static let defaultValue = 1.0
}
private struct InterfaceFineTextScaleKey: EnvironmentKey {
  static let defaultValue = 1.0
}
extension EnvironmentValues {
  var interfaceLayoutScale: Double {
    get { self[InterfaceLayoutScaleKey.self] }
    set { self[InterfaceLayoutScaleKey.self] = newValue }
  }
  var interfaceFineTextScale: Double {
    get { self[InterfaceFineTextScaleKey.self] }
    set { self[InterfaceFineTextScaleKey.self] = newValue }
  }
  var systemReadingType: DynamicTypeSize {
    get { self[SystemReadingTypeKey.self] }
    set { self[SystemReadingTypeKey.self] = newValue }
  }
}
extension InterfaceFont {
  var design: Font.Design {
    switch self { case .system: .default; case .rounded: .rounded; case .serif: .serif; case .monospaced: .monospaced }
  }
}

// 只在应用根部应用一次；正文由 ReaderSurface 单独恢复系统基准并使用阅读偏好。
struct InterfaceTypography: ViewModifier {
  let size: InterfaceTextSize
  let font: InterfaceFont
  @Environment(\.dynamicTypeSize) private var systemSize
  private var adjustedSize: DynamicTypeSize {
    let sizes: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
                                     .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5]
    let index = sizes.firstIndex(of: systemSize) ?? 3
    return sizes[min(sizes.count - 1, max(0, index + size.offset))]
  }
  func body(content: Content) -> some View {
    content.environment(\.systemReadingType, systemSize)
      .environment(\.interfaceLayoutScale, size.layoutScale)
      .environment(\.interfaceFineTextScale, size == .smaller ? 0.8 : 1)
      .dynamicTypeSize(adjustedSize).fontDesign(font.design)
  }
}

// 界面字号与字型拥有独立入口和预览，恢复默认不触碰任何正文阅读设置。
struct InterfaceFontSettingsView: View {
  @ObservedObject var model: AppModel
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      RoundedSettingsPage {
        RoundedSettingsGroup("界面设置") {
          Menu {
            Picker("界面字号", selection: binding(\.interfaceTextSize)) {
              ForEach(InterfaceTextSize.allCases, id: \.self) { Text($0.label).tag($0) }
            }
          } label: {
            RoundedSettingsRow(title: "界面字号", symbol: "textformat.size", value: model.preferences.interfaceTextSize.label)
          }.buttonStyle(FluidButtonStyle())
          RoundedSettingsDivider()
          Menu {
            Picker("界面字型", selection: binding(\.interfaceFont)) {
              ForEach(InterfaceFont.allCases, id: \.self) { Text($0.label).tag($0) }
            }
          } label: {
            RoundedSettingsRow(title: "界面字型", symbol: "textformat", value: model.preferences.interfaceFont.label)
          }.buttonStyle(FluidButtonStyle())
        }
        RoundedSettingsGroup("界面预览") {
          VStack(alignment: .leading, spacing: 12) {
            Text("MioLib 我的阅读空间").font(.title3.weight(.semibold))
            Text("书架 · 阅读笔记 · 1234567890").font(.body)
            Text("选择合适的大小，让菜单和书架更易阅读。").font(.subheadline).foregroundStyle(.secondary)
          }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        RoundedSettingsCard {
          Button {
            var prefs = model.preferences
            prefs.interfaceTextSize = .system
            prefs.interfaceFont = .system
            model.changePreferences(prefs)
          } label: {
            RoundedSettingsRow(title: "恢复跟随系统", symbol: "arrow.counterclockwise", disclosure: false)
          }.buttonStyle(FluidButtonStyle())
        }
        Text("这里只调整软件界面的文字。阅读正文请使用“阅读字体与排版”，两套设置分别保存。")
          .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
      }.navigationTitle("界面字体").navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
      }
    }
  }
  private func binding<T>(_ key: WritableKeyPath<ReaderPreferences, T>) -> Binding<T> {
    Binding(get: { model.preferences[keyPath: key] }, set: { newValue in
      var prefs = model.preferences
      prefs[keyPath: key] = newValue
      model.changePreferences(prefs)
    })
  }
}
