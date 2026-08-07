import SwiftUI

/// Linked-points portal icon: top circle blue while placing source; bottom circle red for destination.
///
/// Style B — the S-curve runs under the nodes; each circle is punched clean then filled/stroked
/// so the link never shows through.
struct PortalPhaseIcon: View {
  enum Phase {
    /// Idle / placing source — top circle filled blue.
    case source
    /// Source placed / placing destination — bottom circle filled red.
    case destination
  }

  var phase: Phase
  var size: CGFloat = 22

  var body: some View {
    Canvas { context, canvasSize in
      let mark = PortalMarkGeometry(size: canvasSize)

      context.stroke(
        mark.linkPath,
        with: .color(.primary.opacity(0.75)),
        style: StrokeStyle(lineWidth: mark.linkWidth, lineCap: .round)
      )

      let topFill: Color? = phase == .source ? .blue : nil
      let bottomFill: Color? = phase == .destination ? .red : nil
      drawCircle(
        context: &context, center: mark.top, radius: mark.radius, fill: topFill,
        lineWidth: mark.circleWidth)
      drawCircle(
        context: &context, center: mark.bottom, radius: mark.radius, fill: bottomFill,
        lineWidth: mark.circleWidth)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  private func drawCircle(
    context: inout GraphicsContext, center: CGPoint, radius: CGFloat, fill: Color?,
    lineWidth: CGFloat
  ) {
    let rect = CGRect(
      x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    let path = Path(ellipseIn: rect)
    // Punch out whatever the link drew inside this disk, then paint the node on top.
    context.blendMode = .destinationOut
    context.fill(path, with: .color(.black))
    context.blendMode = .normal
    if let fill {
      context.fill(path, with: .color(fill))
    }
    context.stroke(path, with: .color(.primary.opacity(0.85)), lineWidth: lineWidth)
  }
}

/// Geometry for style B: link ends under the disks; circles drawn on top hide the join.
struct PortalMarkGeometry {
  let top: CGPoint
  let bottom: CGPoint
  let radius: CGFloat
  let linkPath: Path
  let linkWidth: CGFloat
  let circleWidth: CGFloat

  init(size: CGSize) {
    let w = size.width
    let h = size.height
    let scale = min(w, h)
    top = CGPoint(x: w * 0.30, y: h * 0.30)
    bottom = CGPoint(x: w * 0.70, y: h * 0.70)
    radius = scale * 0.155
    linkWidth = max(1.2, scale * 0.065)
    circleWidth = max(1.1, scale * 0.055)

    let dx = bottom.x - top.x
    let dy = bottom.y - top.y
    let length = hypot(dx, dy)
    let ux = dx / length
    let uy = dy / length
    let px = -uy
    let py = ux

    // Deep inside each disk so the punched circles fully own the join.
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

    var path = Path()
    path.move(to: start)
    path.addCurve(to: end, control1: c1, control2: c2)
    linkPath = path
  }
}
