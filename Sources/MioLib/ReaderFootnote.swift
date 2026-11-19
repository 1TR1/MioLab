import ReadiumNavigator
import ReadiumShared
import SwiftSoup
import SwiftUI

// 小窗使用注释的文字内容，保留段落与换行，并显示插图的替代文字。
struct ReaderFootnote {
  let link: ReadiumShared.Link
  let text: String

  init(link: ReadiumShared.Link, content: String) {
    self.link = link
    text = Self.previewText(from: content)
  }

  // HTML 在本地转成原生文本，小窗可使用阅读配色和系统辅助功能。
  static func previewText(from html: String) -> String {
    guard let body = try? SwiftSoup.parseBodyFragment(html).body() else { return "" }
    let ignoredTags: Set<String> = ["script", "style", "noscript", "template"]
    var lines: [String] = []
    var line = ""

    // 保留块和显式换行，同时去掉源代码缩进形成的多余空白。
    func finishLine() {
      let text = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      if !text.isEmpty { lines.append(text) }
      line.removeAll(keepingCapacity: true)
    }

    // 行内元素的文字按原顺序拼接；注释中的返回链接由小窗按钮代替。
    func visit(_ node: Node) {
      if let text = node as? TextNode {
        line += text.getWholeText()
        return
      }
      guard let element = node as? Element, !ignoredTags.contains(element.tagName()) else { return }
      let role = (try? element.attr("role")) ?? ""
      let type = (try? element.attr("epub:type")) ?? ""
      guard !role.split(whereSeparator: \.isWhitespace).contains("doc-backlink"),
        !type.split(whereSeparator: \.isWhitespace).contains("backlink") else { return }
      if element.isBlock() || element.tagName() == "br" { finishLine() }
      if element.tagName() == "img", let alt = try? element.attr("alt"), !alt.isEmpty {
        line += " " + alt + " "
      }
      for child in element.getChildNodes() { visit(child) }
      if element.isBlock() { finishLine() }
    }

    visit(body)
    finishLine()
    return lines.joined(separator: "\n")
  }
}

// 注释卡沿用单层玻璃底板，标题与按钮随系统字号排版。
struct ReaderFootnoteCard: View {
  let footnote: ReaderFootnote
  let palette: ReaderPagePalette
  let heightLimit: CGFloat
  let jumping: Bool
  let close: () -> Void
  let jump: () -> Void
  @Environment(\.colorScheme) private var systemScheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)
    ViewThatFits(in: .vertical) {
      // 优先使用文字换行后的自然高度，标题与操作区紧随内容。
      panel { noteText }
        .fixedSize(horizontal: false, vertical: true)

      // 未能完整放下时为正文提供滚动区，关闭与跳转保持可见。
      panel {
        ScrollView { noteText }
          .scrollBounceBehavior(.basedOnSize)
          .frame(minHeight: 44, idealHeight: 44)
      }
      // 矮窗口遇到超大字号时，整个面板可以滑动，末尾的跳转仍可到达。
      ScrollView { panel { noteText } }
        .scrollBounceBehavior(.basedOnSize)
    }
    // 保留紧凑的上下内边距，玻璃按内容高度绘制。
    .padding(.horizontal, heightLimit < 320 ? 16 : 22)
    .padding(.vertical, heightLimit < 320 ? 10 : 14)
    .frame(maxWidth: .infinity)
    .background {
      // 卡片留白属于小窗的触控区，窗外由遮罩负责关闭。
      shape.fill(.clear).contentShape(shape).onTapGesture {}
        .accessibilityHidden(true)
    }
    .mioFrostedCard(radius: 32, opaqueBackground: palette.background)
    .environment(\.colorScheme, pageScheme)
    .accessibilityElement(children: .contain)
    .accessibilityAction(.escape, close)
  }

  // 玻璃按阅读主题调整明暗。暖纸色使用浅色对比度，跟随系统时沿用环境。
  private var pageScheme: ColorScheme {
    switch palette.theme {
    case .system: systemScheme
    case .light, .paper: .light
    case .dark: .dark
    }
  }

  // 标题和操作优先分配高度，让正文在两者之间使用剩余阅读空间。
  private func panel<Note: View>(@ViewBuilder note: () -> Note) -> some View {
    VStack(alignment: .leading, spacing: heightLimit < 320 ? 8 : 10) {
      HStack(spacing: 12) {
        Text("注释").font(.title3.weight(.semibold))
          .foregroundStyle(palette.ink)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityAddTraits(.isHeader)
        Button(role: .cancel, action: close) {
          Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
            .foregroundStyle(palette.ink)
            .frame(width: 44, height: 44)
            .background(palette.ink.opacity(0.08), in: Circle())
            .contentShape(Circle())
        }.buttonStyle(FluidButtonStyle()).accessibilityLabel("关闭小窗")
      }.layoutPriority(1)
      note()
      jumpButton.frame(maxWidth: .infinity, alignment: .trailing).layoutPriority(1)
    }
  }

  // 跳转使用系统主操作样式，旧系统与开启减少透明度时使用高对比度的实色按钮。
  @ViewBuilder private var jumpButton: some View {
    let action = Button(action: jump) {
      Label("跳转", systemImage: "arrow.right")
        .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
    }.buttonBorderShape(.capsule).disabled(jumping)
    if #available(iOS 26.0, *), !reduceTransparency {
      action.buttonStyle(.glassProminent)
    } else {
      action.buttonStyle(.borderedProminent)
    }
  }

  // 图片注释的替代文字可能为空，此时仍可打开源书页。
  private var noteText: some View {
    Text(verbatim: footnote.text.isEmpty ? "请跳转到注释所在书页查看。" : footnote.text)
      .font(.body)
      .foregroundStyle(palette.ink)
      .lineSpacing(5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
  }
}

// 顶部独立提示栏不改变阅读区域的尺寸，点叉后继续停在注释处。
struct ReaderFootnoteReturnBar: View {
  let palette: ReaderPagePalette
  let busy: Bool
  let undo: () -> Void
  let close: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Button(action: undo) {
        Label("取消跳转", systemImage: "arrow.uturn.backward")
          .font(.subheadline.weight(.semibold))
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .contentShape(Rectangle())
      }
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.subheadline.weight(.semibold))
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }.accessibilityLabel("关闭此栏")
    }
    .padding(.leading, 16).frame(maxWidth: 260)
    .buttonStyle(.plain).foregroundStyle(palette.ink)
    .background(palette.background, in: Capsule())
    .overlay(Capsule().strokeBorder(palette.ink.opacity(0.14), lineWidth: 1).allowsHitTesting(false))
    .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
    .disabled(busy)
  }
}

// 顺序之外的尾注使用同一书包的原始页面，不向正文会话回传进度。
struct ReaderFootnoteDocument: Identifiable {
  let id = UUID()
  let navigator: EPUBNavigatorViewController
}

// 尾注页在关闭提示栏后仍有返回正文的入口。
struct ReaderFootnoteDocumentView: View {
  @ObservedObject var session: ReaderSession
  let document: ReaderFootnoteDocument
  let palette: ReaderPagePalette

  var body: some View {
    NavigationStack {
      ReaderFootnoteDocumentSurface(navigator: document.navigator)
        .background(palette.background)
        .overlay(alignment: .top) {
          if session.footnoteReturnLocation != nil {
            ReaderFootnoteReturnBar(palette: palette, busy: session.navigatingFootnote,
              undo: session.undoFootnoteJump, close: session.dismissFootnoteReturnBar)
              .padding(.top, 8).padding(.horizontal, 12)
          }
        }
        .navigationTitle("注释")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          if session.footnoteReturnLocation == nil {
            ToolbarItem(placement: .cancellationAction) {
              Button("返回正文", action: session.dismissFootnoteDocument)
            }
          }
        }
    }.presentationDetents([.large]).presentationDragIndicator(.visible)
  }
}

// 保持同一个 Readium 控制器，收起提示栏时不重新加载尾注页。
private struct ReaderFootnoteDocumentSurface: UIViewControllerRepresentable {
  let navigator: EPUBNavigatorViewController
  func makeUIViewController(context: Context) -> EPUBNavigatorViewController { navigator }
  func updateUIViewController(_ controller: EPUBNavigatorViewController, context: Context) {}
}
