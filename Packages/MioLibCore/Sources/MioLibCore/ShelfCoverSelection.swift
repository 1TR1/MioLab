import Foundation

// 书籍列表与四宫格使用相同排序；主排序相同时按标题、ID 稳定排列。
extension BookSort {
  public func ordered(_ books: [Book]) -> [Book] {
    books.sorted { first, second in
      switch self {
      case .title:
        break
      case .imported:
        if first.importedAt != second.importedAt { return first.importedAt > second.importedAt }
      case .recentlyRead:
        let firstDate = first.lastOpenedAt ?? first.importedAt
        let secondDate = second.lastOpenedAt ?? second.importedAt
        if firstDate != secondDate { return firstDate > secondDate }
      }
      // 固定同日期书籍的相对次序，避免重新加载后四宫格的封面随机交换。
      let comparison = first.title.localizedStandardCompare(second.title)
      if comparison != .orderedSame { return comparison == .orderedAscending }
      return first.id.uuidString < second.id.uuidString
    }
  }
}

// 仅取当前书架直属且未删除的前四本书，缺少书籍或封面的格子以 nil 留空。
public enum ShelfCoverSelection {
  public static func slots(folderID: UUID, books: [Book], sort: BookSort) -> [String?] {
    let members = books.filter { $0.folderID == folderID && $0.deletedAt == nil }
    let covers = sort.ordered(members).prefix(4).map(\.effectiveCover)
    return covers + Array(repeating: nil, count: 4 - covers.count)
  }
}
