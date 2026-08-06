import AppKit

/// Two linked circles showing mark-capture phase (source = blue top, destination = red bottom).
@MainActor
final class PortalPhaseIndicatorView: NSView {
  var mode: PortalCaptureMode = .inactive {
    didSet { needsDisplay = true }
  }

  override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 22) }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let top = CGPoint(x: bounds.minX + 7, y: bounds.maxY - 6)
    let bottom = CGPoint(x: bounds.maxX - 7, y: bounds.minY + 6)
    let radius: CGFloat = 4.5

    context.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
    context.setLineWidth(1.5)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: top.x + 2, y: top.y - 2))
    context.addCurve(
      to: CGPoint(x: bottom.x - 2, y: bottom.y + 2),
      control1: CGPoint(x: top.x + 10, y: top.y - 8),
      control2: CGPoint(x: bottom.x - 10, y: bottom.y + 8)
    )
    context.strokePath()

    let topFill: NSColor?
    let bottomFill: NSColor?
    switch mode {
    case .inactive, .source:
      topFill = .systemBlue
      bottomFill = nil
    case .sourcePlaced, .destination:
      topFill = nil
      bottomFill = .systemRed
    }

    drawCircle(at: top, radius: radius, fill: topFill, in: context)
    drawCircle(at: bottom, radius: radius, fill: bottomFill, in: context)
  }

  private func drawCircle(at center: CGPoint, radius: CGFloat, fill: NSColor?, in context: CGContext) {
    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    if let fill {
      context.setFillColor(fill.cgColor)
      context.fillEllipse(in: rect)
    }
    context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.85).cgColor)
    context.setLineWidth(1.25)
    context.strokeEllipse(in: rect)
  }
}
