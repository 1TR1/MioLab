import Foundation
import MioLibCore
import Photos
import ReadiumShared
import UIKit
import WebKit

// Readium 使用自定义资源地址，直接读取正在显示的本地图像后用 Photos 写入相册。
@MainActor final class ReaderImageMenu: NSObject, WKScriptMessageHandler {
  private static let handler = "mioReaderImageMenu"
  private static let world = WKContentWorld.world(name: "MioLib.ReaderImages")
  private weak var host: UIViewController?
  private let publication: Publication
  private let report: (String) -> Void
  private var saving = false

  private init(host: UIViewController, publication: Publication, report: @escaping (String) -> Void) {
    self.host = host
    self.publication = publication
    self.report = report
  }

  // 只给网页书的 Readium 文档安装消息桥，使用隔离环境并让持有者保持弱引用。
  static func install(in controller: WKUserContentController, host: UIViewController,
    publication: Publication, report: @escaping (String) -> Void)
  {
    guard let url = Bundle.module.url(forResource: "ReaderImageMenu", withExtension: "js"),
      let script = try? String(contentsOf: url, encoding: .utf8) else { return }
    controller.add(ReaderImageMenu(host: host, publication: publication, report: report),
      contentWorld: world, name: handler)
    controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd,
      forMainFrameOnly: true, in: world))
  }

  // 校验当前章所在的本地资源路径，只允许保存生成的正文插图。
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard !saving, message.name == Self.handler, message.frameInfo.isMainFrame,
      let pageURL = message.frameInfo.request.url, pageURL.scheme == "readium",
      let image = message.body as? String,
      image.range(of: #"^images/image[0-9]+\.(?:jpg|jpeg|png)$"#, options: .regularExpression) != nil,
      let host, let view = host.viewIfLoaded, view.window != nil, host.presentedViewController == nil else { return }
    let page = pageURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard page.hasSuffix("/article.xhtml"),
      publication.readingOrder.contains(where: { $0.url().string.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == page }),
      let resource = AnyURL(string: String(page.dropLast("article.xhtml".count)) + image),
      let imageResource = publication.get(resource) else { return }

    // 原生菜单在 iPhone 和 iPad 上都可用，只有点“保存图片”时申请相册权限。
    let menu = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
    menu.addAction(UIAlertAction(title: "保存图片", style: .default) { [self] _ in
      Task { await save(imageResource) }
    })
    menu.addAction(UIAlertAction(title: "取消", style: .cancel))
    menu.popoverPresentationController?.sourceView = view
    menu.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
    host.present(menu, animated: true)
  }

  // 保留包内原有的图片编码，不截取书页或从网站再次下载。
  private func save(_ resource: Resource) async {
    guard !saving else { return }
    saving = true
    defer { saving = false }
    do {
      let limit: UInt64 = 6 * 1024 * 1024
      let data = try await resource.read(range: 0..<(limit + 1)).get()
      guard !data.isEmpty, UInt64(data.count) <= limit else {
        throw LibraryError.message("无法读取这张图片")
      }
      let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
      guard access == .authorized || access == .limited else {
        throw LibraryError.message("请在系统设置中允许 MioLib 添加照片后重试。")
      }
      try await PHPhotoLibrary.shared().performChanges {
        PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
      }
      report("图片已保存到照片")
    } catch { report(error.localizedDescription) }
  }
}
