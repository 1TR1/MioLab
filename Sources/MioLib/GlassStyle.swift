import MioLibCore
import SwiftUI
import UIKit

// 新系统交给原生 Liquid Glass 渲染；旧系统保留通透层次，减少透明度时改用实底。
private struct MioGlassSurface: ViewModifier {
  var radius: CGFloat
  var interactive: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    if reduceTransparency {
      content.background(Color(.secondarySystemGroupedBackground), in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    } else if #available(iOS 26.0, *) {
      content.glassEffect(.clear.interactive(interactive), in: shape)
    } else {
      // 仅降低背景材质浓度，文字和图标保持原本对比度；高光留在细薄边缘。
      content.background { shape.fill(.ultraThinMaterial).opacity(0.48) }
        .overlay(shape.strokeBorder(
          LinearGradient(colors: [.white.opacity(0.8), .white.opacity(0.06), .white.opacity(0.4)],
                         startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.65))
        .shadow(color: .black.opacity(0.045), radius: 10, y: 4)
    }
  }
}
extension View {
  // 只在导航和操作层使用玻璃，正文与书封面保持清晰。
  func mioGlass(radius: CGFloat = 28, interactive: Bool = false) -> some View {
    modifier(MioGlassSurface(radius: radius, interactive: interactive))
  }
  // 书架底板采用较浓的毛玻璃，封面独立放在上层，圆角留出更宽的呼吸空间。
  func mioFrostedCard(radius: CGFloat = 30) -> some View {
    modifier(MioFrostedCard(radius: radius))
  }
}

private struct MioFrostedCard: ViewModifier {
  let radius: CGFloat
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    if reduceTransparency {
      content.background(Color(.secondarySystemGroupedBackground), in: shape)
    } else if #available(iOS 26.0, *) {
      // 每个书架使用自己的玻璃容器，邻近的两个书架不会融合成一块底板。
      GlassEffectContainer(spacing: 0) { content.glassEffect(.regular, in: shape) }
    } else {
      content.background(.regularMaterial, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.5), lineWidth: 0.7))
    }
  }
}

// 相邻玻璃控件由系统统一采样，避免重复模糊并支持靠近时的自然融合。
struct MioGlassGroup<Content: View>: View {
  let content: Content
  init(@ViewBuilder content: () -> Content) { self.content = content() }
  var body: some View {
    if #available(iOS 26.0, *) {
      GlassEffectContainer(spacing: 18) { content }
    } else { content }
  }
}

// 按压响应可随连续操作中断，减少动态效果时关闭位移动画。
struct FluidButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
      .opacity((configuration.isPressed ? 0.94 : 1) * (enabled ? 1 : 0.45))
      .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.16), value: configuration.isPressed)
  }
}

// 编辑状态仅用于隐藏兼容底栏，不影响 iPad 分栏和系统导航栈。
struct ShelfEditingKey: PreferenceKey {
  static var defaultValue = false
  static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
struct MioTabDock: View {
  @Binding var selection: Int
  @State private var dragX: CGFloat?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.layoutDirection) private var layoutDirection
  @Environment(\.interfaceLayoutScale) private var scale
  var body: some View {
    GeometryReader { geometry in
      let cellWidth = (geometry.size.width - 12) / 2
      let height = max(52, 62 * scale)
      let selectedIndex = layoutDirection == .rightToLeft ? 1 - selection : selection
      let center = dragX ?? (6 + cellWidth * (CGFloat(selectedIndex) + 0.5))
      let visualIndex = center < geometry.size.width / 2 ? 0 : 1
      let preview = layoutDirection == .rightToLeft ? 1 - visualIndex : visualIndex
      let anchor = 6 + cellWidth * (CGFloat(visualIndex) + 0.5)
      let stretch = dragX == nil || reduceMotion ? 0 : min(20, abs(center - anchor) * 0.24)
      ZStack(alignment: .leading) {
        // 底座保持实色；选中镜片完全去掉蓝色填充，以无色边缘高光形成液态层。
        Capsule().fill(Color(.secondarySystemGroupedBackground))
          .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6))
          .shadow(color: .black.opacity(0.055), radius: 10, y: 3)
        MioDockLens(tracking: dragX != nil)
          .frame(width: cellWidth - 4 + stretch,
                 height: dragX != nil && !reduceMotion ? max(height + 8, 70 * scale) : max(44, 50 * scale))
          .offset(x: center - (cellWidth - 4 + stretch) / 2)
          .allowsHitTesting(false)
        HStack(spacing: 0) {
          tab(0, title: "书架", symbol: "books.vertical", active: preview == 0)
          tab(1, title: "我的", symbol: "person.crop.circle", active: preview == 1)
        }.padding(.horizontal, 6)
      }.frame(height: height).contentShape(Capsule())
        // 从按下开始鼓起，跨入口时镜片拉伸，松开后收回；点击和拖动共用一套逻辑。
        .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { event in
          let target = min(geometry.size.width - cellWidth / 2 - 6, max(cellWidth / 2 + 6, event.location.x))
          if dragX == nil {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.16)) { dragX = target }
          } else { dragX = target }
        }.onEnded { event in
          let index = event.location.x < geometry.size.width / 2 ? 0 : 1
          withAnimation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.24)) {
            selection = layoutDirection == .rightToLeft ? 1 - index : index
            dragX = nil
          }
        })
        .animation(reduceMotion || dragX != nil ? nil : .spring(duration: 0.28, bounce: 0.16), value: selection)
    }.frame(height: max(52, 62 * scale)).frame(maxWidth: 340 * scale)
      .padding(.horizontal, 28 * scale).padding(.top, 10 * scale).padding(.bottom, 10 * scale)
      .frame(maxWidth: .infinity)
      .background(Color(.systemGroupedBackground).ignoresSafeArea(edges: .bottom))
  }
  // 选中高光在两个入口间连续移动，按压缩放与状态切换使用同一短弹簧。
  private func tab(_ tag: Int, title: String, symbol: String, active: Bool) -> some View {
    Button {
      withAnimation(reduceMotion ? nil : .spring(duration: 0.26, bounce: 0.2)) { selection = tag }
    } label: {
      VStack(spacing: 3) {
        Image(systemName: symbol).font(.system(size: max(16, 19 * scale), weight: .medium))
        Text(title).font(.caption2.weight(.medium))
      }.frame(maxWidth: .infinity).frame(minHeight: max(44, 48 * scale))
        .foregroundStyle(active ? Color.accentColor : .secondary)
        .scaleEffect(active && dragX != nil && !reduceMotion ? 1.05 : 1)
        .contentShape(Capsule())
    }.buttonStyle(FluidButtonStyle()).accessibilityAddTraits(selection == tag ? .isSelected : [])
  }
}

// 镜片没有色块，保留透明主体、双层细边及拖动时的柔和光泽。
private struct MioDockLens: View {
  let tracking: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  var body: some View {
    Group {
      if reduceTransparency {
        Capsule().fill(Color(.tertiarySystemGroupedBackground))
      } else if #available(iOS 26.0, *) {
        Capsule().fill(.clear).glassEffect(.clear.interactive(), in: Capsule())
      } else {
        Capsule().fill(.ultraThinMaterial).opacity(0.1)
      }
    }.overlay(Capsule().strokeBorder(
      LinearGradient(colors: [.white.opacity(0.95), Color.primary.opacity(0.08), .white.opacity(0.65)],
                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
      .overlay(Capsule().inset(by: 2).strokeBorder(.white.opacity(tracking ? 0.45 : 0.18), lineWidth: 0.6))
      .shadow(color: .black.opacity(tracking ? 0.1 : 0.035), radius: tracking ? 9 : 5, y: 3)
  }
}

// 排版滑块显示真实吸附点并逐格取值；拖动时提供轻触感，VoiceOver 保留系统滑块操作。
struct MagneticSlider: View {
  let title: String
  @Binding var value: Double
  let stops: [Double]
  let display: String
  var adjustmentButtons = false
  @State private var dragValue: Double?
  @State private var feedback = UISelectionFeedbackGenerator()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.layoutDirection) private var layoutDirection
  private var lower: Double { stops.first ?? 0 }
  private var upper: Double { stops.last ?? 1 }
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(title)
        Spacer()
        Text(display).monospacedDigit().foregroundStyle(.secondary).contentTransition(.numericText())
      }.font(.subheadline)
      HStack(spacing: 10) {
        if adjustmentButtons { adjustButton(increasing: false) }
        track
        if adjustmentButtons { adjustButton(increasing: true) }
      }
    }.padding(.vertical, 5)
  }
  // 格点与轨道使用同一条中心线；吸附范围内贴近格点，其余位置跟随手指连续移动。
  private var track: some View {
    GeometryReader { geometry in
      let width = max(1, geometry.size.width - 28)
      let displayed = dragValue ?? value
      let fraction = CGFloat(min(1, max(0, (displayed - lower) / max(0.000001, upper - lower))))
      let visual = layoutDirection == .rightToLeft ? 1 - fraction : fraction
      ZStack(alignment: .leading) {
        Capsule().fill(Color.secondary.opacity(0.18)).frame(height: 6)
        Capsule().fill(Color.accentColor.opacity(0.75)).frame(width: width * fraction, height: 6)
          .frame(maxWidth: .infinity, alignment: layoutDirection == .rightToLeft ? .trailing : .leading)
        ForEach(stops, id: \.self) { stop in
          let position = CGFloat((stop - lower) / max(0.000001, upper - lower))
          Circle().fill(stop <= value ? Color.white.opacity(0.85) : Color.secondary.opacity(0.55))
            .frame(width: 4, height: 4)
            .offset(x: width * (layoutDirection == .rightToLeft ? 1 - position : position) - 2)
        }
        Circle().fill(Color.white).frame(width: 26, height: 26)
          .overlay(Circle().strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
          .shadow(color: .black.opacity(0.16), radius: 3, y: 2)
          .scaleEffect(dragValue != nil && !reduceMotion ? 1.1 : 1)
          .offset(x: width * visual - 13)
      }.padding(.horizontal, 14).frame(height: 44).contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { event in
          let fraction = min(1, max(0, Double((event.location.x - 14) / width)))
          let raw = lower + (layoutDirection == .rightToLeft ? 1 - fraction : fraction) * (upper - lower)
          let snapped = ReaderSnap.closest(raw, to: stops)
          dragValue = abs(raw - snapped) / max(0.000001, upper - lower) * Double(width) < 9 ? snapped : raw
          if value != snapped { value = snapped; feedback.selectionChanged() }
          feedback.prepare()
        }.onEnded { _ in
          withAnimation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.12)) { dragValue = nil }
        })
    }.frame(height: 44)
      .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityValue(display)
      .accessibilityAdjustableAction { direction in
        if direction == .increment { adjust(increasing: true) }
        else if direction == .decrement { adjust(increasing: false) }
      }
  }
  // 两侧按钮有独立的 44 点触控区，到达范围边界后禁用对应方向。
  private func adjustButton(increasing: Bool) -> some View {
    Button { adjust(increasing: increasing) } label: {
      Image(systemName: increasing ? "plus" : "minus").font(.body.weight(.semibold))
        .frame(width: 44, height: 44).mioGlass(radius: 22, interactive: true)
    }.buttonStyle(FluidButtonStyle()).accessibilityLabel("\(increasing ? "增大" : "减小")\(title)")
      .disabled(increasing ? value >= upper : value <= lower)
  }
  private func adjust(increasing: Bool) {
    withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) {
      value = ReaderSnap.adjacent(value, in: stops, increasing: increasing)
    }
    feedback.selectionChanged()
  }
}
