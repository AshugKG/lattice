import Foundation

public struct JumpLocation: Equatable, Sendable {
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

  public func isEquivalent(to other: JumpLocation) -> Bool {
    documentFingerprint == other.documentFingerprint && pageIndex == other.pageIndex
      && abs(viewportCenter.x - other.viewportCenter.x) < 0.002
      && abs(viewportCenter.y - other.viewportCenter.y) < 0.002
      && abs(scaleFactor - other.scaleFactor) < 0.01
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
    append(location, to: &backward)
    forward.removeAll()
  }

  public mutating func goBackward(from current: JumpLocation) -> JumpLocation? {
    guard let target = backward.popLast() else { return nil }
    append(current, to: &forward)
    return target
  }

  public mutating func goForward(from current: JumpLocation) -> JumpLocation? {
    guard let target = forward.popLast() else { return nil }
    append(current, to: &backward)
    return target
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
