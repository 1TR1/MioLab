import MioLibCore
import SwiftUI

// 四个格子始终占据固定位置，不重复封面，也不在空格绘制占位图标。
struct ShelfMosaicCover: View {
  let urls: [URL?]
  var body: some View {
    GeometryReader { geometry in
      // 水平与垂直间距按 2:3 缩放，每张小封面也保持原有纵向比例。
      let gap = geometry.size.width * 0.04
      let width = max(0, (geometry.size.width - gap) / 2)
      let height = max(0, (geometry.size.height - gap * 1.5) / 2)
      VStack(spacing: gap * 1.5) {
        ForEach(0..<2, id: \.self) { row in
          HStack(spacing: gap) {
            ForEach(0..<2, id: \.self) { column in
              // 固定按左上、右上、左下、右下填充，空格保持透明。
              let index = row * 2 + column
              Group {
                if index < urls.count, let url = urls[index] {
                  CoverView(url: url)
                } else {
                  Color.clear
                }
              }.frame(width: width, height: height)
            }
          }
        }
      }
    }.clipped().accessibilityHidden(true)
  }
}
