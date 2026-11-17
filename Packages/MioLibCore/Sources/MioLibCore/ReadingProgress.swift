import Foundation

// 阅读进度与定位分开保存：末页显示完成，Locator 仍保留真实的页首或段落位置。
public enum ReadingProgress {
  public static func normalized(_ value: Double) -> Double {
    value.isFinite ? min(1, max(0, value)) : 0
  }

  // PDF 页码从零开始；单页文件打开即是末页，也应报告 100%。
  public static func pdf(page: Int, count: Int) -> Double {
    guard count > 0 else { return 0 }
    let index = min(count - 1, max(0, page))
    if index == count - 1 { return 1 }
    return Double(index) / Double(max(1, count - 1))
  }

  // EPUB 使用最后一个阅读资源的可见尾端判断完成，避免最后一页的页首进度停在 99%。
  public static func text(raw: Double, isLastResource: Bool, visibleResourceEnd: Double?) -> Double {
    if isLastResource, let end = visibleResourceEnd, end.isFinite, end >= 1 - 0.000001 { return 1 }
    return normalized(raw)
  }

  // 向下取整，尚未到末页时不会因为四舍五入提前显示 100%。
  public static func percent(_ value: Double) -> Int {
    let value = normalized(value)
    if value == 1 { return 100 }
    return min(99, Int(floor(value * 100 + 0.000000001)))
  }
}

// 层级遍历使用稳定 ID，封面来源包含当前文件夹及其所有子文件夹中的书籍。
public enum LibraryHierarchy {
  public static func descendants(of id: UUID, folders: [LibraryFolder]) -> Set<UUID> {
    var result: Set<UUID> = [id]
    var changed = true
    while changed {
      changed = false
      for folder in folders where folder.parentID.map(result.contains) == true {
        if result.insert(folder.id).inserted { changed = true }
      }
    }
    return result
  }
}
