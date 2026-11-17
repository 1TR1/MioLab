import MioLibCore
import SwiftUI

// 内置目录始终是第一层导航，下方固定提供页码控制，长目录不会挤走跳页入口。
struct ReaderContentsView: View {
  @ObservedObject var session: ReaderSession
  @Environment(\.dismiss) private var dismiss
  @State private var thumbnails = false
  var body: some View {
    NavigationStack {
      // 用真实的纵向布局分配高度，不再把底部定位卡片叠放到目录滚动区域上。
      GeometryReader { geometry in
        VStack(spacing: 0) {
          contentsList.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
          Divider()
          ReaderPageNavigator(session: session, compact: geometry.size.height < 420) { dismiss() }
            .fixedSize(horizontal: false, vertical: true).padding(12)
        }.background(Color(.systemGroupedBackground))
      }
      .navigationTitle("目录").navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .topBarLeading) {
          if session.host.pdfView != nil {
            Button("缩略图", systemImage: "square.grid.2x2") { thumbnails = true }
          }
        }
        ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
      }
      .sheet(isPresented: $thumbnails) {
        NavigationStack {
          if let pdf = session.host.pdfView {
            PDFThumbnails(pdf: pdf).navigationTitle("页面缩略图").navigationBarTitleDisplayMode(.inline)
              .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { thumbnails = false } } }
          }
        }
      }
    }.presentationDetents([.large]).presentationDragIndicator(.visible)
  }
  // 长目录独立滚动；弹出键盘或改变字号时仍遵循父容器给定的可用高度。
  private var contentsList: some View {
    List {
        Section("本书目录") {
          OutlineGroup(session.outline, children: \.children) { node in
            Button {
              session.navigate(node.entry)
              dismiss()
            } label: {
              HStack {
                Text(node.entry.title).foregroundStyle(.primary).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                if let page = node.entry.page {
                  Text("\(page + 1)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
              }.padding(.vertical, 5)
            }.buttonStyle(.plain).disabled(node.entry.link == nil && node.entry.page == nil)
          }
        }
    }.listStyle(.plain).scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively).overlay {
        if session.outline.isEmpty {
          ContentUnavailableView("本书没有内置目录", systemImage: "list.bullet",
                                 description: Text("可使用下方滑动条或输入编号定位。"))
        }
    }
  }
}

// 拖动只更新预览编号，松手才定位，避免长篇 EPUB 在拖动中反复加载章节。
private struct ReaderPageNavigator: View {
  @ObservedObject var session: ReaderSession
  let compact: Bool
  let onJump: () -> Void
  @State private var preview = 1.0
  @State private var dragging = false
  @State private var input = ""
  @FocusState private var enteringPage: Bool
  private var target: Int? { ReaderPageNavigation.parse(input, count: session.pageCount) }
  var body: some View {
    VStack(spacing: compact ? 5 : 10) {
      HStack {
        Text(session.pageUnit == "页" ? "页码" : "阅读位置").font(.subheadline.weight(.semibold))
        Spacer()
        Text("\(Int(preview)) / \(session.pageCount)")
          .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
      }
      Slider(value: $preview, in: 1...Double(max(2, session.pageCount)), step: 1) { editing in
        dragging = editing
        if !editing { session.navigatePage(Int(preview)) }
      }.disabled(session.pageCount <= 1)
        .accessibilityLabel(session.pageUnit == "页" ? "选择页码" : "选择阅读位置")
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("输入\(session.pageUnit == "页" ? "页码" : "位置")（1～\(session.pageCount)）", text: $input)
          .keyboardType(.numberPad).focused($enteringPage).submitLabel(.go).onSubmit(jump)
          .accessibilityLabel("输入跳转编号")
        Button("跳转", action: jump).fontWeight(.semibold).disabled(target == nil)
      }.padding(12).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
      if session.pageUnit != "页" && !compact {
        Text("位置编号保持固定，不随字号和屏幕大小改变。")
          .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
      }
    }.padding(compact ? 10 : 16).mioGlass(radius: 28, interactive: true)
      .onAppear { preview = Double(session.currentPage) }
      .onChange(of: session.currentPage) { _, page in if !dragging { preview = Double(page) } }
      .onChange(of: session.pageCount) { _, count in
        preview = Double(ReaderPageNavigation.page(Int(preview), count: count))
      }
  }
  // 越界或空输入保持在原处，成功输入后收起面板，让正文直接显示目标页。
  private func jump() {
    guard let target else { return }
    enteringPage = false
    session.navigatePage(target)
    onJump()
  }
}
