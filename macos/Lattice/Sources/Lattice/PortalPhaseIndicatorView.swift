import AppKit

/// Two linked circles showing portal-capture phase (source = blue top, destination = red bottom).
/// Style B — link runs under the nodes; disks are cleared then redrawn so the join never shows through.
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

    let scale = min(bounds.width, bounds.height)
    let top = CGPoint(x: bounds.minX + scale * 0.28, y: bounds.maxY - scale * 0.28)
    let bottom = CGPoint(x: bounds.maxX - scale * 0.28, y: bounds.minY + scale * 0.28)
    let radius = scale * 0.20

    let dx = bottom.x - top.x
    let dy = bottom.y - top.y
    let length = hypot(dx, dy)
    let ux = dx / length
    let uy = dy / length
    let px = -uy
    let py = ux

    let attach = radius * 0.40
    let start = CGPoint(x: top.x + ux * attach, y: top.y + uy * attach)
    let end = CGPoint(x: bottom.x - ux * attach, y: bottom.y - uy * attach)
    let bulge = length * 0.16
    let c1 = CGPoint(
      x: top.x + ux * length * 0.34 + px * bulge,
      y: top.y + uy * length * 0.34 + py * bulge
    )
    let c2 = CGPoint(
      x: top.x + ux * length * 0.66 - px * bulge,
      y: top.y + uy * length * 0.66 - py * bulge
    )

    context.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
    context.setLineWidth(1.5)
    context.setLineCap(.round)
    context.move(to: start)
    context.addCurve(to: end, control1: c1, control2: c2)
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
    // Clear the link under this disk, then paint the node.
    context.setBlendMode(.clear)
    context.fillEllipse(in: rect)
    context.setBlendMode(.normal)
    if let fill {
      context.setFillColor(fill.cgColor)
      context.fillEllipse(in: rect)
    }
    context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.85).cgColor)
    context.setLineWidth(1.25)
    context.strokeEllipse(in: rect)
  }
}
