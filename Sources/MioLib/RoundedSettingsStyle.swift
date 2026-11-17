import SwiftUI

// 参考系统设置的灰底、大圆角卡片、宽组间距，页面内容在底栏上方独立滚动。
struct RoundedSettingsPage<Content: View>: View {
  let content: Content
  @Environment(\.interfaceLayoutScale) private var scale
  init(@ViewBuilder content: () -> Content) { self.content = content() }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 32 * scale) { content }
        .padding(.horizontal, 16 * scale).padding(.top, 12 * scale).padding(.bottom, 24 * scale)
        .frame(maxWidth: 700).frame(maxWidth: .infinity)
    }.background(Color(.systemGroupedBackground).ignoresSafeArea())
  }
}

// 分组只负责圆润的白色或深色实底，不把正文和每行文字叠成多层玻璃。
struct RoundedSettingsCard<Content: View>: View {
  let content: Content
  @Environment(\.interfaceLayoutScale) private var scale
  init(@ViewBuilder content: () -> Content) { self.content = content() }
  var body: some View {
    VStack(spacing: 0) { content }
      .background(Color(.secondarySystemGroupedBackground),
                  in: RoundedRectangle(cornerRadius: 30 * scale, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: 30 * scale, style: .continuous))
  }
}
struct RoundedSettingsGroup<Content: View>: View {
  let title: String
  let content: Content
  @Environment(\.interfaceLayoutScale) private var scale
  init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
  var body: some View {
    VStack(alignment: .leading, spacing: 10 * scale) {
      Text(title).font(.body.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 18 * scale)
      RoundedSettingsCard { content }
    }
  }
}

// 标题直接以较大的文字起排，去掉前置装饰图标，保留圆角、行高和右侧导航提示。
struct RoundedSettingsRow: View {
  let title: String
  let symbol: String
  var color: Color = .blue
  var value: String? = nil
  var disclosure = true
  // 放大基础文字，同时继续跟随系统的辅助功能字号缩放。
  @ScaledMetric(relativeTo: .body) private var titleSize = 20.0
  @ScaledMetric(relativeTo: .body) private var valueSize = 19.0
  @Environment(\.interfaceLayoutScale) private var scale
  @Environment(\.interfaceFineTextScale) private var textScale
  var body: some View {
    HStack(spacing: 14 * scale) {
      Text(title).font(.system(size: titleSize * textScale)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      if let value { Text(value).font(.system(size: valueSize * textScale)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8) }
      if disclosure { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
    }.padding(.horizontal, 18 * scale).padding(.vertical, 14 * scale)
      .frame(minHeight: max(44, 60 * scale)).contentShape(Rectangle())
  }
}
struct RoundedSettingsDivider: View {
  @Environment(\.interfaceLayoutScale) private var scale
  var body: some View { Divider().padding(.horizontal, 18 * scale) }
}
