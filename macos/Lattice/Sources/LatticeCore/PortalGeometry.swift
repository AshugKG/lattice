import CoreGraphics

public enum PortalGeometry {
  public static func normalized(rect: CGRect, in pageBounds: CGRect) -> NormalizedRect? {
    let pageBounds = pageBounds.standardized
    let rect = rect.standardized.intersection(pageBounds)
    guard pageBounds.width > 0, pageBounds.height > 0, !rect.isNull, !rect.isEmpty else {
      return nil
    }
    let normalized = NormalizedRect(
      x: (rect.minX - pageBounds.minX) / pageBounds.width,
      y: (rect.minY - pageBounds.minY) / pageBounds.height,
      width: rect.width / pageBounds.width,
      height: rect.height / pageBounds.height
    )
    return normalized.isValid ? normalized : nil
  }

  public static func pageRect(for normalized: NormalizedRect, in pageBounds: CGRect) -> CGRect? {
    let pageBounds = pageBounds.standardized
    guard normalized.isValid, pageBounds.width > 0, pageBounds.height > 0 else { return nil }
    return CGRect(
      x: pageBounds.minX + pageBounds.width * normalized.x,
      y: pageBounds.minY + pageBounds.height * normalized.y,
      width: pageBounds.width * normalized.width,
      height: pageBounds.height * normalized.height
    ).intersection(pageBounds)
  }
}
