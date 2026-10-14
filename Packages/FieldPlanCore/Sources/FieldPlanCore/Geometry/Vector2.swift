import Foundation

/// 2D vector / point in plan coordinates.
///
/// FieldPlan plan coordinates are meters, mathematical convention:
/// +X to the right, +Y "up" on the plan sheet, counter-clockwise polygons
/// have positive signed area. Renderers that use screen coordinates
/// (SwiftUI, SVG, PDF) are responsible for flipping Y.
public struct Vec2: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)

    // MARK: Arithmetic

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func * (s: Double, a: Vec2) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func / (a: Vec2, s: Double) -> Vec2 { Vec2(a.x / s, a.y / s) }
    public static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }

    public static func += (a: inout Vec2, b: Vec2) { a = a + b }
    public static func -= (a: inout Vec2, b: Vec2) { a = a - b }

    // MARK: Measure

    public var length: Double { (x * x + y * y).squareRoot() }
    public var lengthSquared: Double { x * x + y * y }

    public func distance(to other: Vec2) -> Double { (self - other).length }

    public func dot(_ other: Vec2) -> Double { x * other.x + y * other.y }

    /// Z component of the 3D cross product; positive when `other` is
    /// counter-clockwise from `self`.
    public func cross(_ other: Vec2) -> Double { x * other.y - y * other.x }

    /// Angle of the vector in radians, in (-pi, pi].
    public var angle: Double { atan2(y, x) }

    public var normalized: Vec2 {
        let len = length
        guard len > 1e-12 else { return .zero }
        return self / len
    }

    /// Perpendicular vector, rotated +90 degrees (counter-clockwise).
    public var perpendicular: Vec2 { Vec2(-y, x) }

    public func rotated(by radians: Double) -> Vec2 {
        let c = cos(radians)
        let s = sin(radians)
        return Vec2(x * c - y * s, x * s + y * c)
    }

    public func rotated(by radians: Double, around pivot: Vec2) -> Vec2 {
        (self - pivot).rotated(by: radians) + pivot
    }

    public func lerp(to other: Vec2, t: Double) -> Vec2 {
        self + (other - self) * t
    }

    public func approximatelyEquals(_ other: Vec2, tolerance: Double = 1e-9) -> Bool {
        distance(to: other) <= tolerance
    }

    public func midpoint(_ other: Vec2) -> Vec2 { (self + other) * 0.5 }
}

/// 3D vector used when bridging scan data (world space, meters).
public struct Vec3: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3(0, 0, 0)

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }

    public static func / (a: Vec3, s: Double) -> Vec3 { Vec3(a.x / s, a.y / s, a.z / s) }
    public static func += (a: inout Vec3, b: Vec3) { a = a + b }

    public var length: Double { (x * x + y * y + z * z).squareRoot() }

    public func distance(to other: Vec3) -> Double { (self - other).length }

    public func dot(_ other: Vec3) -> Double { x * other.x + y * other.y + z * other.z }

    public func cross(_ other: Vec3) -> Vec3 {
        Vec3(y * other.z - z * other.y,
             z * other.x - x * other.z,
             x * other.y - y * other.x)
    }

    public var normalized: Vec3 {
        let len = length
        guard len > 1e-12 else { return .zero }
        return self / len
    }

    /// Projects a scan-space point (Y up) onto plan coordinates.
    /// RoomPlan world space is right-handed with +Y up; the floor plane is XZ.
    /// Plan X = world X, plan Y = -world Z so that looking down at the floor
    /// from above yields a conventional plan orientation.
    public var planProjection: Vec2 { Vec2(x, -z) }
}

/// Axis-aligned bounding rectangle in plan coordinates.
public struct Rect2: Codable, Hashable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public static let null = Rect2(
        minX: .greatestFiniteMagnitude,
        minY: .greatestFiniteMagnitude,
        maxX: -.greatestFiniteMagnitude,
        maxY: -.greatestFiniteMagnitude
    )

    public var isNull: Bool { minX > maxX || minY > maxY }
    public var width: Double { max(0, maxX - minX) }
    public var height: Double { max(0, maxY - minY) }
    public var center: Vec2 { Vec2((minX + maxX) / 2, (minY + maxY) / 2) }

    public init(containing points: [Vec2]) {
        self = .null
        for p in points { include(p) }
    }

    public mutating func include(_ p: Vec2) {
        minX = Swift.min(minX, p.x)
        minY = Swift.min(minY, p.y)
        maxX = Swift.max(maxX, p.x)
        maxY = Swift.max(maxY, p.y)
    }

    public mutating func include(_ other: Rect2) {
        guard !other.isNull else { return }
        minX = Swift.min(minX, other.minX)
        minY = Swift.min(minY, other.minY)
        maxX = Swift.max(maxX, other.maxX)
        maxY = Swift.max(maxY, other.maxY)
    }

    public func union(_ other: Rect2) -> Rect2 {
        var r = self
        r.include(other)
        return r
    }

    public func expanded(by margin: Double) -> Rect2 {
        guard !isNull else { return self }
        return Rect2(minX: minX - margin, minY: minY - margin, maxX: maxX + margin, maxY: maxY + margin)
    }

    public func contains(_ p: Vec2) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }

    public func intersects(_ other: Rect2) -> Bool {
        !(other.minX > maxX || other.maxX < minX || other.minY > maxY || other.maxY < minY)
    }
}

public enum GeometryAngle {
    /// Normalizes an angle to (-pi, pi].
    public static func normalize(_ radians: Double) -> Double {
        var a = radians.truncatingRemainder(dividingBy: 2 * .pi)
        if a <= -.pi { a += 2 * .pi }
        if a > .pi { a -= 2 * .pi }
        return a
    }

    /// Smallest absolute difference between two angles in radians.
    public static func difference(_ a: Double, _ b: Double) -> Double {
        abs(normalize(a - b))
    }

    public static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
    public static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
}
