import Foundation

/// One cropped excerpt on a PDF page (e.g. AI study plan).
/// `topY` / `bottomY` are normalized from the **top** of the page crop box (0 = top, 1 = bottom).
public struct ReadingStop: Codable, Equatable, Identifiable, Sendable, Hashable {
  public let id: String
  public let pageIndex: Int
  public let topY: Double
  public let bottomY: Double
  public let highlight: NormalizedRect?
  public let label: String?
  public let note: String?

  public init(
    id: String,
    pageIndex: Int,
    topY: Double = 0,
    bottomY: Double = 1,
    highlight: NormalizedRect? = nil,
    label: String? = nil,
    note: String? = nil
  ) {
    self.id = id
    self.pageIndex = pageIndex
    self.topY = topY
    self.bottomY = bottomY
    self.highlight = highlight
    self.label = label
    self.note = note
  }

  public var isValid: Bool {
    guard pageIndex >= 0 else { return false }
    guard topY.isFinite, bottomY.isFinite else { return false }
    guard topY >= 0, bottomY <= 1, bottomY > topY else { return false }
    if let highlight {
      guard highlight.isValid else { return false }
    }
    return true
  }

  /// Minimum vertical span after clamping (avoids zero-height crops).
  public var clampedBand: (top: Double, bottom: Double) {
    let top = min(1, max(0, topY))
    var bottom = min(1, max(0, bottomY))
    if bottom <= top {
      bottom = min(1, top + 0.08)
    }
    if bottom <= top {
      return (0, min(1, max(0.08, bottom)))
    }
    return (top, bottom)
  }
}

/// Ordered reading path for a PDF document. Each stop becomes one cropped excerpt page.
public struct ReadingGuide: Codable, Equatable, Sendable, Hashable {
  public let documentPath: String?
  public let stops: [ReadingStop]

  public init(documentPath: String? = nil, stops: [ReadingStop]) {
    self.documentPath = documentPath
    self.stops = stops.filter(\.isValid)
  }

  public var isEmpty: Bool { stops.isEmpty }
}
