import Foundation

public struct JumpLocation: Codable, Equatable, Sendable {
  public static let homeFingerprint = "lattice:home"

  public let documentFingerprint: String
  public let documentPath: String
  public let pageIndex: Int
  public let viewportCenter: NormalizedPoint
  public let scaleFactor: Double

  public init(
    documentFingerprint: String,
    documentPath: String,
    pageIndex: Int,
    viewportCenter: NormalizedPoint,
    scaleFactor: Double
  ) {
    self.documentFingerprint = documentFingerprint
    self.documentPath = documentPath
    self.pageIndex = pageIndex
    self.viewportCenter = viewportCenter
    self.scaleFactor = scaleFactor
  }

  /// Session-only sentinel for the recents home screen in the Vim jump list.
  public static var home: JumpLocation {
    JumpLocation(
      documentFingerprint: homeFingerprint,
      documentPath: "",
      pageIndex: 0,
      viewportCenter: NormalizedPoint(x: 0.5, y: 0.5),
      scaleFactor: 1
    )
  }

  public var isHome: Bool { documentFingerprint == Self.homeFingerprint }

  public func isEquivalent(to other: JumpLocation) -> Bool {
    if isHome || other.isHome { return isHome && other.isHome }
    return documentFingerprint == other.documentFingerprint && pageIndex == other.pageIndex
      && abs(viewportCenter.x - other.viewportCenter.x) < 0.002
      && abs(viewportCenter.y - other.viewportCenter.y) < 0.002
      && abs(scaleFactor - other.scaleFactor) < 0.01
  }

  public func clamped(pageCount: Int, minimumScale: Double = 0.25, maximumScale: Double = 4)
    -> JumpLocation
  {
    JumpLocation(
      documentFingerprint: documentFingerprint,
      documentPath: documentPath,
      pageIndex: min(max(0, pageIndex), max(0, pageCount - 1)),
      viewportCenter: NormalizedPoint(
        x: viewportCenter.x.isFinite ? min(1, max(0, viewportCenter.x)) : 0.5,
        y: viewportCenter.y.isFinite ? min(1, max(0, viewportCenter.y)) : 0.5
      ),
      scaleFactor: scaleFactor.isFinite
        ? min(maximumScale, max(minimumScale, scaleFactor)) : 1
    )
  }
}

public struct JumpList: Sendable {
  public let capacity: Int
  public private(set) var backward: [JumpLocation] = []
  public private(set) var forward: [JumpLocation] = []

  public init(capacity: Int = 100) {
    self.capacity = max(1, capacity)
  }

  public mutating func recordBeforeJump(_ location: JumpLocation) {
    guard !backward.last.isSomeEquivalent(to: location) else { return }
    append(location, to: &backward)
    forward.removeAll()
  }

  public mutating func goBackward(from current: JumpLocation?) -> JumpLocation? {
    guard let target = backward.popLast() else { return nil }
    if let current { append(current, to: &forward) }
    return target
  }

  public mutating func goForward(from current: JumpLocation?) -> JumpLocation? {
    guard let target = forward.popLast() else { return nil }
    if let current { append(current, to: &backward) }
    return target
  }

  /// Undo a failed backward jump so async restore misses don't drop history.
  public mutating func cancelBackward(target: JumpLocation, current: JumpLocation?) {
    if let current, forward.last.isSomeEquivalent(to: current) {
      _ = forward.popLast()
    }
    append(target, to: &backward)
  }

  /// Undo a failed forward jump so async restore misses don't drop history.
  public mutating func cancelForward(target: JumpLocation, current: JumpLocation?) {
    if let current, backward.last.isSomeEquivalent(to: current) {
      _ = backward.popLast()
    }
    append(target, to: &forward)
  }

  public mutating func rewriteFingerprint(
    from oldFingerprint: String,
    to newFingerprint: String,
    path: String
  ) {
    guard oldFingerprint != newFingerprint else { return }
    backward = backward.map {
      rewrite($0, from: oldFingerprint, to: newFingerprint, path: path)
    }
    forward = forward.map {
      rewrite($0, from: oldFingerprint, to: newFingerprint, path: path)
    }
  }

  private func rewrite(
    _ location: JumpLocation,
    from oldFingerprint: String,
    to newFingerprint: String,
    path: String
  ) -> JumpLocation {
    guard !location.isHome else { return location }
    let matchesFingerprint = location.documentFingerprint == oldFingerprint
    let matchesPendingPath =
      location.documentPath == path
      && (location.documentFingerprint.hasPrefix("pending:")
        || location.documentFingerprint == oldFingerprint)
    guard matchesFingerprint || matchesPendingPath else { return location }
    return JumpLocation(
      documentFingerprint: newFingerprint,
      documentPath: path,
      pageIndex: location.pageIndex,
      viewportCenter: location.viewportCenter,
      scaleFactor: location.scaleFactor
    )
  }

  private func append(_ location: JumpLocation, to stack: inout [JumpLocation]) {
    guard !stack.last.isSomeEquivalent(to: location) else { return }
    stack.append(location)
    if stack.count > capacity {
      stack.removeFirst(stack.count - capacity)
    }
  }
}

extension Optional where Wrapped == JumpLocation {
  fileprivate func isSomeEquivalent(to location: JumpLocation) -> Bool {
    self?.isEquivalent(to: location) == true
  }
}
