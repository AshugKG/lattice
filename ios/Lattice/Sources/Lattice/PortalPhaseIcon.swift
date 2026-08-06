import SwiftUI

/// Linked-points portal icon: top circle blue while placing source; bottom circle red for destination.
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
      let w = canvasSize.width
      let h = canvasSize.height
      let top = CGPoint(x: w * 0.28, y: h * 0.28)
      let bottom = CGPoint(x: w * 0.72, y: h * 0.72)
      let radius = min(w, h) * 0.16

      var curve = Path()
      curve.move(to: CGPoint(x: top.x + radius * 0.4, y: top.y + radius * 0.4))
      curve.addCurve(
        to: CGPoint(x: bottom.x - radius * 0.4, y: bottom.y - radius * 0.4),
        control1: CGPoint(x: w * 0.7, y: h * 0.2),
        control2: CGPoint(x: w * 0.3, y: h * 0.8)
      )
      context.stroke(
        curve, with: .color(.primary.opacity(0.75)),
        style: StrokeStyle(lineWidth: 1.6, lineCap: .round))

      let topFill: Color? = phase == .source ? .blue : nil
      let bottomFill: Color? = phase == .destination ? .red : nil
      drawCircle(context: context, center: top, radius: radius, fill: topFill)
      drawCircle(context: context, center: bottom, radius: radius, fill: bottomFill)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  private func drawCircle(context: GraphicsContext, center: CGPoint, radius: CGFloat, fill: Color?) {
    let rect = CGRect(
      x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    let path = Path(ellipseIn: rect)
    if let fill {
      context.fill(path, with: .color(fill))
    }
    context.stroke(path, with: .color(.primary.opacity(0.85)), lineWidth: 1.4)
  }
}
