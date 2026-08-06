import Foundation

/// External open-at-location request (e.g. from LeetMath).
public struct LaunchGoto: Equatable, Sendable {
  public let pageIndex: Int
  public let bounds: NormalizedRect
  public let label: String?

  public init(pageIndex: Int, bounds: NormalizedRect, label: String? = nil) {
    self.pageIndex = pageIndex
    self.bounds = bounds
    self.label = label
  }
}

public struct LaunchArguments: Equatable, Sendable {
  public let pdfURL: URL?
  public let goto: LaunchGoto?

  public init(pdfURL: URL?, goto: LaunchGoto?) {
    self.pdfURL = pdfURL
    self.goto = goto
  }

  /// Parse `Lattice /path/book.pdf --page-index N --rect x,y,w,h [--label TEXT]`.
  public static func parse(_ arguments: [String]) -> LaunchArguments {
    let args = Array(arguments.dropFirst())
    var pdfURL: URL?
    var pageIndex: Int?
    var bounds: NormalizedRect?
    var label: String?

    var i = 0
    while i < args.count {
      let arg = args[i]
      if arg == "--page-index", i + 1 < args.count, let value = Int(args[i + 1]) {
        pageIndex = value
        i += 2
        continue
      }
      if arg == "--rect", i + 1 < args.count {
        bounds = parseRect(args[i + 1])
        i += 2
        continue
      }
      if arg == "--label", i + 1 < args.count {
        label = args[i + 1]
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
    if let pageIndex, let bounds, bounds.isValid {
      goto = LaunchGoto(pageIndex: pageIndex, bounds: bounds, label: label)
    } else {
      goto = nil
    }
    return LaunchArguments(pdfURL: pdfURL, goto: goto)
  }

  private static func parseRect(_ raw: String) -> NormalizedRect? {
    let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 4,
      let x = Double(parts[0]),
      let y = Double(parts[1]),
      let w = Double(parts[2]),
      let h = Double(parts[3])
    else { return nil }
    return NormalizedRect(x: x, y: y, width: w, height: h)
  }
}
