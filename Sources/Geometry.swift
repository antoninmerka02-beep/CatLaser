import Foundation
import CoreGraphics

// MARK: - Vector helpers

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }

    var length: CGFloat { (x * x + y * y).squareRoot() }

    var normalized: CGPoint {
        let l = length
        return l > 1e-9 ? CGPoint(x: x / l, y: y / l) : .zero
    }

    /// Perpendicular vector (rotated +90°).
    var perp: CGPoint { CGPoint(x: -y, y: x) }

    func dot(_ o: CGPoint) -> CGFloat { x * o.x + y * o.y }

    func distance(to o: CGPoint) -> CGFloat { (self - o).length }

    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGPoint {
        CGPoint(x: min(hi, max(lo, x)), y: min(hi, max(lo, y)))
    }
}

// MARK: - Homography

/// 3×3 projective transform, row-major, m[8] normalised to 1.
struct Homography: Codable, Equatable {
    var m: [Double]

    func apply(_ p: CGPoint) -> CGPoint? {
        let x = Double(p.x), y = Double(p.y)
        let w = m[6] * x + m[7] * y + m[8]
        guard abs(w) > 1e-9 else { return nil }
        let u = (m[0] * x + m[1] * y + m[2]) / w
        let v = (m[3] * x + m[4] * y + m[5]) / w
        guard u.isFinite, v.isFinite else { return nil }
        return CGPoint(x: u, y: v)
    }

    /// Returns w – positive means the point lies "in front" (same side as the calibration points).
    func w(_ p: CGPoint) -> Double {
        m[6] * Double(p.x) + m[7] * Double(p.y) + m[8]
    }

    func inverted() -> Homography? {
        let a = m
        let c00 = a[4] * a[8] - a[5] * a[7]
        let c01 = -(a[3] * a[8] - a[5] * a[6])
        let c02 = a[3] * a[7] - a[4] * a[6]
        let det = a[0] * c00 + a[1] * c01 + a[2] * c02
        guard abs(det) > 1e-12 else { return nil }
        let inv: [Double] = [
            c00,
            -(a[1] * a[8] - a[2] * a[7]),
            a[1] * a[5] - a[2] * a[4],
            c01,
            a[0] * a[8] - a[2] * a[6],
            -(a[0] * a[5] - a[2] * a[3]),
            c02,
            -(a[0] * a[7] - a[1] * a[6]),
            a[0] * a[4] - a[1] * a[3]
        ].map { $0 / det }
        guard abs(inv[8]) > 1e-12 else { return Homography(m: inv) }
        return Homography(m: inv.map { $0 / inv[8] })
    }

    /// Least-squares DLT fit (h33 = 1). src and dst should be roughly 0…1 scaled for stability.
    static func fit(src: [CGPoint], dst: [CGPoint]) -> Homography? {
        guard src.count == dst.count, src.count >= 4 else { return nil }
        var ata = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8)
        var atb = [Double](repeating: 0, count: 8)
        for i in 0..<src.count {
            let x = Double(src[i].x), y = Double(src[i].y)
            let u = Double(dst[i].x), v = Double(dst[i].y)
            let rows: [([Double], Double)] = [
                ([x, y, 1, 0, 0, 0, -u * x, -u * y], u),
                ([0, 0, 0, x, y, 1, -v * x, -v * y], v)
            ]
            for (r, b) in rows {
                for j in 0..<8 {
                    atb[j] += r[j] * b
                    for k in 0..<8 { ata[j][k] += r[j] * r[k] }
                }
            }
        }
        guard let h = solve(ata, atb) else { return nil }
        return Homography(m: h + [1])
    }

    /// Gaussian elimination with partial pivoting.
    private static func solve(_ aIn: [[Double]], _ bIn: [Double]) -> [Double]? {
        var a = aIn
        var b = bIn
        let n = b.count
        for col in 0..<n {
            var piv = col
            for r in (col + 1)..<n where abs(a[r][col]) > abs(a[piv][col]) { piv = r }
            guard abs(a[piv][col]) > 1e-12 else { return nil }
            if piv != col {
                a.swapAt(piv, col)
                b.swapAt(piv, col)
            }
            for r in 0..<n where r != col {
                let f = a[r][col] / a[col][col]
                if f == 0 { continue }
                for k in col..<n { a[r][k] -= f * a[col][k] }
                b[r] -= f * b[col]
            }
        }
        return (0..<n).map { b[$0] / a[$0][$0] }
    }
}

// MARK: - Polygons

enum Poly {
    static func contains(_ poly: [CGPoint], _ p: CGPoint) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) {
                let xCross = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
                if p.x < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    static func closestPointOnSegment(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> CGPoint {
        let ab = b - a
        let l2 = ab.dot(ab)
        guard l2 > 1e-12 else { return a }
        let t = max(0, min(1, (p - a).dot(ab) / l2))
        return a + ab * t
    }

    static func closestPointOnBoundary(_ poly: [CGPoint], _ p: CGPoint) -> CGPoint {
        guard let first = poly.first else { return p }
        var best = first
        var bestD = CGFloat.greatestFiniteMagnitude
        for i in 0..<poly.count {
            let q = closestPointOnSegment(poly[i], poly[(i + 1) % poly.count], p)
            let d = q.distance(to: p)
            if d < bestD { bestD = d; best = q }
        }
        return best
    }

    static func distanceToBoundary(_ poly: [CGPoint], _ p: CGPoint) -> CGFloat {
        closestPointOnBoundary(poly, p).distance(to: p)
    }

    static func centroid(_ poly: [CGPoint]) -> CGPoint {
        guard !poly.isEmpty else { return .zero }
        var a: CGFloat = 0, cx: CGFloat = 0, cy: CGFloat = 0
        for i in 0..<poly.count {
            let p = poly[i], q = poly[(i + 1) % poly.count]
            let cross = p.x * q.y - q.x * p.y
            a += cross
            cx += (p.x + q.x) * cross
            cy += (p.y + q.y) * cross
        }
        if abs(a) < 1e-9 {
            let s = poly.reduce(CGPoint.zero, +)
            return s * (1 / CGFloat(poly.count))
        }
        return CGPoint(x: cx / (3 * a), y: cy / (3 * a))
    }

    /// Andrew's monotone chain convex hull.
    static func convexHull(_ pts: [CGPoint]) -> [CGPoint] {
        let p = pts.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard p.count >= 3 else { return p }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for q in p {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        var upper: [CGPoint] = []
        for q in p.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Moves a point into the polygon (onto the boundary, then `margin` towards the centroid).
    static func pullInside(_ poly: [CGPoint], _ p: CGPoint, margin: CGFloat) -> CGPoint {
        guard poly.count >= 3 else { return p }
        if contains(poly, p) && distanceToBoundary(poly, p) >= margin { return p }
        let c = centroid(poly)
        var q = contains(poly, p) ? p : closestPointOnBoundary(poly, p)
        let toC = c - q
        let step = min(margin, toC.length * 0.9)
        q = q + toC.normalized * step
        return q
    }
}
