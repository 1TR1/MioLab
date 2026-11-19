import MioLibCore
import SwiftUI

// @main 是 xtool 主库的原生应用入口；后续视图共享同一书库模型。
@main
struct MioLibApp: App {
  @StateObject private var model = AppModel()
  @Environment(\.scenePhase) private var scenePhase
  var body: some Scene {
    WindowGroup {
      RootView(model: model)
        // 应用字号与系统字型独立保存，阅读器的原生内容恢复自己的字号基准。
        .modifier(InterfaceTypography(size: model.preferences.interfaceTextSize, font: model.preferences.interfaceFont))
        // 系统表单与目录也保留宽松的最小行高，适合触控和大字号。
        .environment(\.defaultMinListRowHeight, max(44, 58 * model.preferences.interfaceTextSize.layoutScale))
        .tint(.blue)
        .preferredColorScheme(
          model.preferences.theme == .dark
            ? .dark
            : model.preferences.theme == .light || model.preferences.theme == .paper ? .light : nil
        )
        .onOpenURL { model.receive($0) }
        // 生命周期事件不等待防抖计时，保存书架布局、排序和阅读偏好。
        .onChange(of: scenePhase, initial: true) { _, phase in
          // 网页缓存独立使用系统后台任务，退回书架或锁屏时保持队列断点。
          model.webBookCache.sceneChanged(phase)
          if phase != .active { Task { await model.flushPreferences() } }
        }
        // 回到前台立即接收，保持前台时每三秒检查；后台不持续占用电量或网络。
        .task(id: scenePhase) {
          guard scenePhase == .active else { return }
          while !Task.isCancelled {
            await model.receiveCalibreUSB()
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
          }
        }
    }
  }
}
