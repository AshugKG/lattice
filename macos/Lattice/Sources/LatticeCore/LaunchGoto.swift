import Foundation

/// External open-at-location request (e.g. from LeetMath).
/// `topY` is normalized from the **top** of the page crop box (0 = top, 1 = bottom).
public struct LaunchGoto: Equatable, Sendable {
  public let pageIndex: Int
  public let topY: Double
  public let label: String?

  public init(pageIndex: Int, topY: Double, label: String? = nil) {
    self.pageIndex = pageIndex
    self.topY = topY
    self.label = label
  }

  public var isValid: Bool {
    pageIndex >= 0 && topY.isFinite && topY >= 0 && topY <= 1
  }
}

public struct LaunchArguments: Equatable, Sendable {
  public let pdfURL: URL?
  public let goto: LaunchGoto?

  public init(pdfURL: URL?, goto: LaunchGoto?) {
    self.pdfURL = pdfURL
    self.goto = goto
  }

  /// Parse `Lattice /path/book.pdf --page-index N --top 0.42 [--label TEXT]`.
  public static func parse(_ arguments: [String]) -> LaunchArguments {
    let args = Array(arguments.dropFirst())
    var pdfURL: URL?
    var pageIndex: Int?
    var topY: Double?
    var label: String?

    var i = 0
    while i < args.count {
      let arg = args[i]
      if arg == "--page-index", i + 1 < args.count, let value = Int(args[i + 1]) {
        pageIndex = value
        i += 2
        continue
      }
      if arg == "--top", i + 1 < args.count, let value = Double(args[i + 1]) {
        topY = value
        i += 2
        continue
      }
      if arg == "--label", i + 1 < args.count {
        label = args[i + 1]
        i += 2
        continue
      }
      // Legacy --rect x,y,w,h → use y as topY
      if arg == "--rect", i + 1 < args.count {
        let parts = args[i + 1].split(separator: ",").map {
          $0.trimmingCharacters(in: .whitespaces)
        }
        if parts.count == 4, let y = Double(parts[1]) {
          topY = y
        }
        i += 2
        continue
      }
      if arg.hasPrefix("--") {
        i += 1
        continue
      }
      if arg.lowercased().hasSuffix(".pdf") {
        pdfURL = URL(fileURLWithPath: arg)
      }
      i += 1
    }

    let goto: LaunchGoto?
    if let pageIndex, let topY {
      let request = LaunchGoto(pageIndex: pageIndex, topY: topY, label: label)
      goto = request.isValid ? request : nil
    } else {
      goto = nil
    }
    return LaunchArguments(pdfURL: pdfURL, goto: goto)
  }
}
