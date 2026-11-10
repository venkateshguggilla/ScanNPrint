import Foundation

/// Finds how far the content of a scan is turned, from the positions of its non-background pixels.
/// At the right angle the content's rows and columns line up, so their edges are sharpest: text lines,
/// card and photo borders all turn into clean steps in the row and column profiles. The score is the
/// sum of squared steps, which peaks sharply there.
enum Deskew {
    // Below this the content is already straight; turning it would only soften it.
    private static let minUsefulDegrees = 0.1
    private static let coarseStep = 0.5
    private static let fineStep = 0.05
    private static let maxPoints = 200_000

    /// The clockwise angle (within ±`maxDegrees`) the content at the given pixel positions is turned by,
    /// or 0 when there's too little to go on.
    static func estimateAngle(_ points: [SIMD2<Float>], maxDegrees: Double = Clip.maxStraightenDegrees) -> Double {
        guard points.count >= 50 else { return 0 }
        var random = SplitMix64(seed: 1234)
        let sample = thin(points, &random)

        // Jitter each point within its pixel; otherwise the pixel grid itself scores best at ±45°.
        var xs = [Double](repeating: 0, count: sample.count)
        var ys = [Double](repeating: 0, count: sample.count)
        var sx = 0.0, sy = 0.0
        for (i, p) in sample.enumerated() {
            xs[i] = Double(p.x) + random.nextUnit()
            ys[i] = Double(p.y) + random.nextUnit()
            sx += xs[i]
            sy += ys[i]
        }
        let cx = sx / Double(sample.count), cy = sy / Double(sample.count)
        var radius = 0.0
        for i in xs.indices {
            xs[i] -= cx
            ys[i] -= cy
            radius = max(radius, (xs[i] * xs[i] + ys[i] * ys[i]).squareRoot())
        }
        radius += 2
        let binCount = Int(2 * radius) + 3
        var rows = [Double](repeating: 0, count: binCount)
        var cols = [Double](repeating: 0, count: binCount)

        func score(_ degrees: Double) -> Double {
            let rad = degrees * .pi / 180, c = cos(rad), s = sin(rad)
            return rows.withUnsafeMutableBufferPointer { r in
                cols.withUnsafeMutableBufferPointer { k in
                    r.update(repeating: 0)
                    k.update(repeating: 0)
                    xs.withUnsafeBufferPointer { x in
                        ys.withUnsafeBufferPointer { y in
                            for i in 0..<x.count {
                                // Split each point between the two nearest bins so the profile is smooth.
                                let u = x[i] * c + y[i] * s + radius
                                let v = -x[i] * s + y[i] * c + radius
                                let ui = Int(u), vi = Int(v)
                                let uf = u - Double(ui), vf = v - Double(vi)
                                k[ui] += 1 - uf
                                k[ui + 1] += uf
                                r[vi] += 1 - vf
                                r[vi + 1] += vf
                            }
                        }
                    }
                    return steps(r) + steps(k)
                }
            }
        }

        var best = 0.0, bestScore = score(0)
        let coarseCount = Int((2 * maxDegrees / coarseStep).rounded())
        for k in 0...coarseCount {
            let a = -maxDegrees + Double(k) * coarseStep
            let s = score(a)
            if s > bestScore { (best, bestScore) = (a, s) }
        }
        let coarse = best
        let fineCount = Int((2 * coarseStep / fineStep).rounded())
        for k in 0...fineCount {
            let a = coarse - coarseStep + Double(k) * fineStep
            let s = score(a)
            if s > bestScore { (best, bestScore) = (a, s) }
        }

        best = (best / fineStep).rounded() * fineStep
        return abs(best) < minUsefulDegrees ? 0 : min(max(best, -maxDegrees), maxDegrees)
    }

    /// The tightest rectangle at `angleDegrees` around the points, ignoring rows and columns (in that turned
    /// frame) holding fewer than `minCount` points, so dust specks don't stretch it. Nil when nothing is left.
    static func bounds(_ points: [SIMD2<Float>], angleDegrees: Double, minCount: Int = 1) -> TiltedRect? {
        guard !points.isEmpty else { return nil }
        var sx = 0.0, sy = 0.0
        for p in points {
            sx += Double(p.x) + 0.5
            sy += Double(p.y) + 0.5
        }
        let cx = sx / Double(points.count), cy = sy / Double(points.count)
        var radius = 0.0
        for p in points {
            let dx = Double(p.x) + 0.5 - cx, dy = Double(p.y) + 0.5 - cy
            radius = max(radius, (dx * dx + dy * dy).squareRoot())
        }
        radius += 2
        let rad = angleDegrees * .pi / 180, c = cos(rad), s = sin(rad)
        var rows = [Int](repeating: 0, count: Int(2 * radius) + 2)
        var cols = rows
        for p in points {
            let dx = Double(p.x) + 0.5 - cx, dy = Double(p.y) + 0.5 - cy
            cols[Int(dx * c + dy * s + radius)] += 1
            rows[Int(-dx * s + dy * c + radius)] += 1
        }
        let need = max(1, minCount)
        guard let left = cols.firstIndex(where: { $0 >= need }), let right = cols.lastIndex(where: { $0 >= need }),
              let top = rows.firstIndex(where: { $0 >= need }), let bottom = rows.lastIndex(where: { $0 >= need }),
              right >= left, bottom >= top else { return nil }

        // Bin i covers [i - radius, i + 1 - radius) in the turned frame.
        let lx = Double(left + right + 1) / 2 - radius, ly = Double(top + bottom + 1) / 2 - radius
        return TiltedRect(centerX: cx + lx * c - ly * s, centerY: cy + lx * s + ly * c,
                          width: Double(right - left + 1), height: Double(bottom - top + 1), angleDegrees: angleDegrees)
    }

    private static func steps(_ profile: UnsafeMutableBufferPointer<Double>) -> Double {
        var sum = 0.0
        for i in 1..<profile.count {
            let d = profile[i] - profile[i - 1]
            sum += d * d
        }
        return sum
    }

    /// Random rather than strided thinning: a stride leaves a lattice that scores like straight content.
    private static func thin(_ points: [SIMD2<Float>], _ random: inout SplitMix64) -> [SIMD2<Float>] {
        guard points.count > maxPoints else { return points }
        return (0..<maxPoints).map { _ in points[Int(random.next() % UInt64(points.count))] }
    }
}

/// Small deterministic generator so detection gives the same answer every time.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
