import Foundation

// MARK: - Independent wall measurement from the mesh (brief §7, §28)
//
// RoomPlan's wall is one estimate. The LiDAR mesh next to it is the evidence
// that estimate came from, and a line fitted straight to that mesh is a
// second, independent estimate of the same wall. It is recorded as the
// element's alternate measurement — never substituted for RoomPlan's value —
// so the accuracy framework can compare both against the tape and say which
// one deserves to be primary.

public enum WallFitter {

    public struct Fit: Hashable, Sendable {
        public var start: Vec2
        public var end: Vec2
        /// RMS lateral distance of the inliers from the fitted line, meters.
        public var residual: Double
        public var inlierCount: Int
        public var sampleCount: Int

        public var length: Double { start.distance(to: end) }

        public var alternate: AlternateMeasurement {
            AlternateMeasurement(method: "meshLineFit", value: length, residual: residual, sampleCount: inlierCount)
        }
    }

    public struct Options: Sendable {
        /// How far either side of RoomPlan's line to look for wall faces.
        public var lateralReach = 0.30
        /// How far past either end of the wall to look.
        public var endReach = 0.15
        public var minimumPoints = 30
        public var inlierDistance = 0.02
        public var iterations = 64
        /// Faces this close to the floor or ceiling are skirting and cornice.
        public var minimumHeightAboveFloor = 0.15
        public var maximumHeightAboveFloor = 2.2

        public init() {}
    }

    /// Fits a line to the wall-classified mesh faces around `wall`, or nil
    /// when there is not enough of it.
    public static func fit(
        wall: Wall,
        chunks: [MeshChunk],
        floorElevation: Double?,
        ceilingElevation: Double? = nil,
        classifier: MeshFaceClassifier = MeshFaceClassifier(),
        options: Options = Options()
    ) -> Fit? {
        let direction = wall.direction
        guard direction.length > 0.5 else { return nil }
        let normal = direction.perpendicular

        var points: [Vec2] = []
        for chunk in chunks {
            for face in 0..<chunk.faceCount {
                let centroid = chunk.faceCentroid(face)
                if let floor = floorElevation {
                    let height = centroid.y - floor
                    guard height >= options.minimumHeightAboveFloor, height <= options.maximumHeightAboveFloor else { continue }
                }
                let p = centroid.planProjection
                let relative = p - wall.start
                let along = relative.dot(direction)
                guard along >= -options.endReach, along <= wall.length + options.endReach else { continue }
                guard abs(relative.dot(normal)) <= options.lateralReach else { continue }
                guard classifier.classify(chunk, face: face, floorElevation: floorElevation,
                                          ceilingElevation: ceilingElevation) == .wall else { continue }
                points.append(p)
            }
        }
        guard points.count >= options.minimumPoints else { return nil }

        // RANSAC on pairs, deterministic so the same session fits the same.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15 &+ UInt64(points.count)
        func next() -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(points.count))
        }
        var bestInliers: [Int] = []
        for _ in 0..<options.iterations {
            let i = next()
            var j = next()
            var attempts = 0
            while j == i && attempts < 8 { j = next(); attempts += 1 }
            guard i != j else { continue }
            let d = (points[j] - points[i]).normalized
            guard d.length > 0.5 else { continue }
            let n = d.perpendicular
            var inliers: [Int] = []
            for (k, p) in points.enumerated() where abs((p - points[i]).dot(n)) <= options.inlierDistance {
                inliers.append(k)
            }
            if inliers.count > bestInliers.count { bestInliers = inliers }
        }
        guard bestInliers.count >= options.minimumPoints else { return nil }

        // Refit on the inliers by principal axis.
        let inlierPoints = bestInliers.map { points[$0] }
        var mean = Vec2.zero
        for p in inlierPoints { mean += p }
        mean = mean / Double(inlierPoints.count)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in inlierPoints {
            let dx = p.x - mean.x
            let dy = p.y - mean.y
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        var fitted = Vec2(cos(angle), sin(angle))
        if fitted.dot(direction) < 0 { fitted = fitted * -1 }
        let fittedNormal = fitted.perpendicular

        var alongs: [Double] = []
        var squares = 0.0
        for p in inlierPoints {
            let rel = p - mean
            alongs.append(rel.dot(fitted))
            let lateral = rel.dot(fittedNormal)
            squares += lateral * lateral
        }
        alongs.sort()
        let lo = AccuracyStatistics.percentile(alongs, 0.02)
        let hi = AccuracyStatistics.percentile(alongs, 0.98)
        return Fit(
            start: mean + fitted * lo,
            end: mean + fitted * hi,
            residual: (squares / Double(inlierPoints.count)).squareRoot(),
            inlierCount: inlierPoints.count,
            sampleCount: points.count)
    }
}
