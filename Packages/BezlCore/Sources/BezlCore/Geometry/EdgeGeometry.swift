import Foundation

/// Shape of one display's rim, in points, with a TOP-LEFT origin (shader space).
public struct EdgeGeometry: Sendable, Equatable {
    public struct NotchRect: Sendable, Equatable {
        public var x: Double
        public var width: Double
        public var height: Double
    }

    public var width: Double
    public var height: Double
    public var topCornerRadius: Double
    public var bottomCornerRadius: Double
    /// The camera housing cut-out, if the display has one.
    public var notch: NotchRect?
    public var notchCornerRadius: Double

    public init(width: Double, height: Double, topCornerRadius: Double, bottomCornerRadius: Double,
                notch: NotchRect?, notchCornerRadius: Double = 8) {
        self.width = width
        self.height = height
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.notch = notch
        self.notchCornerRadius = notchCornerRadius
    }

    /// Default rounded top corners on notched (built-in MacBook) displays; square elsewhere.
    public static let notchedTopCornerRadius = 10.0

    /// Builds geometry from the values `NSScreen` exposes publicly.
    /// - Parameters:
    ///   - safeAreaTop: `screen.safeAreaInsets.top` (0 when there is no notch).
    ///   - auxiliaryLeftWidth: `screen.auxiliaryTopLeftArea?.width` (nil when there is no notch).
    ///   - auxiliaryRightWidth: `screen.auxiliaryTopRightArea?.width`.
    ///   - cornerRadiusOverride: user-chosen radius for all corners, if any.
    public static func make(width: Double, height: Double, safeAreaTop: Double,
                            auxiliaryLeftWidth: Double?, auxiliaryRightWidth: Double?,
                            cornerRadiusOverride: Double? = nil) -> EdgeGeometry {
        var notch: NotchRect?
        if safeAreaTop > 0, let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth {
            let notchWidth = width - left - right
            if notchWidth > 0 {
                notch = NotchRect(x: left, width: notchWidth, height: safeAreaTop)
            }
        }
        let top = cornerRadiusOverride ?? (notch != nil ? notchedTopCornerRadius : 0)
        let bottom = cornerRadiusOverride ?? 0
        return EdgeGeometry(width: width, height: height, topCornerRadius: top,
                            bottomCornerRadius: bottom, notch: notch)
    }

    /// Distance from a point (top-left origin) inward to the nearest lit edge; negative outside
    /// the screen or inside the notch. Mirrors the Metal shader so it can be unit tested.
    public func inwardDistance(x px: Double, y py: Double, followNotch: Bool) -> Double {
        let cx = width / 2, cy = height / 2
        // Screen rounded box: y-down, so p.y > 0 is the bottom half.
        let screen = Self.roundBox(px: px - cx, py: py - cy, hx: cx, hy: cy,
                                   radius: py - cy > 0 ? bottomCornerRadius : topCornerRadius)
        var d = -screen
        if followNotch, let n = notch {
            let extend = 40.0
            let nhx = n.width / 2, nhy = (n.height + extend) / 2
            let ncx = n.x + nhx, ncy = (n.height - extend) / 2
            let ny = py - ncy
            let notchD = Self.roundBox(px: px - ncx, py: ny, hx: nhx, hy: nhy,
                                       radius: ny > 0 ? notchCornerRadius : 0)
            d = min(d, notchD)
        }
        return d
    }

    /// Signed distance to a rounded box centered at the origin (negative inside).
    static func roundBox(px: Double, py: Double, hx: Double, hy: Double, radius r: Double) -> Double {
        let qx = abs(px) - hx + r, qy = abs(py) - hy + r
        let outside = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot()
        return min(max(qx, qy), 0) + outside - r
    }
}
