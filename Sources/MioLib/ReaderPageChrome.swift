import MioLibCore
import SwiftUI
import UIKit

// 继续使用现有阅读主题；页眉和页脚与 Readium 的原有白色、黑色及暖纸色一致。
struct ReaderPagePalette {
  let theme: ReaderTheme
  private var isDark: Bool {
    theme == .dark || (theme == .system && UITraitCollection.current.userInterfaceStyle == .dark)
  }
  var background: Color {
    if theme == .paper { return Color(red: 250 / 255, green: 244 / 255, blue: 232 / 255) }
    if theme == .system { return Color(uiColor: .systemBackground) }
    return theme == .dark ? .black : .white
  }
  var ink: Color {
    if theme == .system { return Color(uiColor: .label) }
    return isDark ? .white : Color(red: 18 / 255, green: 18 / 255, blue: 18 / 255)
  }
}

// 电量只在阅读页显示期间监听，关闭后恢复此前的监听状态。
@MainActor final class ReaderBatteryStatus: ObservableObject {
  @Published private(set) var level: Float = -1
  @Published private(set) var charging = false
  private var previousMonitoring: Bool?
  func start() {
    guard previousMonitoring == nil else { return }
    previousMonitoring = UIDevice.current.isBatteryMonitoringEnabled
    UIDevice.current.isBatteryMonitoringEnabled = true
    refresh()
  }
  func refresh() {
    level = UIDevice.current.batteryLevel
    charging = [.charging, .full].contains(UIDevice.current.batteryState)
  }
  func stop() {
    guard let previousMonitoring else { return }
    UIDevice.current.isBatteryMonitoringEnabled = previousMonitoring
    self.previousMonitoring = nil
  }
  // 使用系统电池图标，未知电量时不显示虚构读数。
  var symbol: String {
    if charging { return "battery.100percent.bolt" }
    let step = min(4, max(0, Int((level * 4).rounded()))) * 25
    return "battery.\(step)percent"
  }
}

// 底部常驻真实电量、24 小时时钟和当前分页；滚动模式显示进度，避免伪装成固定页码。
struct ReaderPageFooter: View {
  @ObservedObject var session: ReaderSession
  @StateObject private var battery = ReaderBatteryStatus()
  var body: some View {
    HStack(spacing: 7) {
      if battery.level >= 0 {
        Image(systemName: battery.symbol).font(.system(size: 20))
          .accessibilityLabel("电量 \(Int(battery.level * 100))%")
      }
      TimelineView(.periodic(from: .now, by: 30)) { context in
        Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
          .locale(Locale(identifier: "zh_CN")))
      }.accessibilityLabel("当前时间")
      Spacer()
      Text(session.footerLabel).accessibilityLabel(session.footerAccessibilityLabel)
    }.font(.system(size: 11)).monospacedDigit().frame(height: 32)
      .onAppear { battery.start() }
      .onDisappear { battery.stop() }
      .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) {
        _ in battery.refresh()
      }
      .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) {
        _ in battery.refresh()
      }
  }
}
