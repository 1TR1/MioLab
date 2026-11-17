import Foundation

// 页码输入、滑动定位和无障碍增减共用边界规则，外部页码从 1 开始。
public enum ReaderPageNavigation {
  public static func page(_ value: Int, count: Int) -> Int {
    min(max(1, count), max(1, value))
  }
  public static func index(_ value: Int, count: Int) -> Int {
    page(value, count: count) - 1
  }
  public static func parse(_ text: String, count: Int) -> Int? {
    guard count > 0, let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
      value >= 1, value <= count else { return nil }
    return value
  }
}

// 排版滑动条按步长吸附；浮点误差归一化，异常输入不会传入阅读引擎。
public enum ReaderSnap {
  // 字号与其他排版轨道一样使用等差锚点，视觉触点间距和每次增减保持一致。
  public static let fontSizes: [Double] = [75, 100, 125, 150, 175, 200]
  public static let lineHeights: [Double] = [1.2, 1.4, 1.6, 1.8, 2, 2.2, 2.4]
  public static let margins: [Double] = [0.5, 1, 1.5, 2, 2.5, 3]
  public static func closest(_ value: Double, to points: [Double]) -> Double {
    let valid = points.filter(\.isFinite).sorted()
    guard value.isFinite else { return valid.first ?? 0 }
    return valid.min { abs($0 - value) < abs($1 - value) } ?? value
  }
  // 增减按钮和 VoiceOver 使用相同锚点，旧字号落在两格之间时也能正确前后移动。
  public static func adjacent(_ value: Double, in points: [Double], increasing: Bool) -> Double {
    let valid = points.filter(\.isFinite).sorted()
    if increasing { return valid.first { $0 > value + 0.000001 } ?? valid.last ?? value }
    return valid.last { $0 < value - 0.000001 } ?? valid.first ?? value
  }
  public static func value(_ value: Double, in range: ClosedRange<Double>, step: Double) -> Double {
    guard value.isFinite, step.isFinite, step > 0 else { return range.lowerBound }
    let clamped = min(range.upperBound, max(range.lowerBound, value))
    let snapped = range.lowerBound + ((clamped - range.lowerBound) / step).rounded() * step
    return min(range.upperBound, max(range.lowerBound, (snapped * 1_000_000).rounded() / 1_000_000))
  }
}
