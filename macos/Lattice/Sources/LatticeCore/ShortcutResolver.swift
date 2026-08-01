import Foundation

public enum ReaderCommand: Equatable, Sendable {
  case open
  case help
  case scrollDown
  case scrollUp
  case scrollLeft
  case scrollRight
  case halfDown
  case halfUp
  case documentStart
  case documentEnd
  case nextPage
  case previousPage
  case zoomIn
  case zoomOut
  case fitWidth
  case find
  case capturePortal
}

public struct ShortcutModifiers: OptionSet, Sendable {
  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  public static let command = Self(rawValue: 1 << 0)
  public static let control = Self(rawValue: 1 << 1)
}

public struct ShortcutResolver: Sendable {
  private var lastG: TimeInterval = 0

  public init() {}

  public mutating func resolve(
    key: String,
    modifiers: ShortcutModifiers = [],
    timestamp: TimeInterval
  ) -> ReaderCommand? {
    let normalized = key.lowercased()
    if modifiers.contains(.command) {
      if normalized == "o" { return .open }
      if normalized == "f" { return .find }
    }
    if modifiers.contains(.control) {
      if normalized == "d" { return .halfDown }
      if normalized == "u" { return .halfUp }
    }

    if key == "g" {
      defer { lastG = timestamp }
      return timestamp - lastG < 0.65 ? .documentStart : nil
    }

    return [
      "o": .open,
      "?": .help,
      "j": .scrollDown,
      "k": .scrollUp,
      "h": .scrollLeft,
      "l": .scrollRight,
      "G": .documentEnd,
      "]": .nextPage,
      "[": .previousPage,
      "+": .zoomIn,
      "=": .zoomIn,
      "-": .zoomOut,
      "0": .fitWidth,
      "p": .capturePortal,
    ][key]
  }
}
