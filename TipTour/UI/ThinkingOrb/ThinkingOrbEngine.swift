import CoreGraphics
import Foundation
import SwiftUI

// Ported from kairos (tag archive/2026-09-23-frozen, apps/kairos/Sources/ThinkingOrb).
// Based on https://github.com/Jakubantalik/thinking-orbs — MIT, Copyright (c) 2026
// Jakub Antalik; full text in LICENSE-THINKING-ORBS.txt beside this file.
// Internal monochrome dotted-orb engine (thinking-orbs / inkform lineage).
// Honestly 3D: rotated, depth-shaded, z-sorted. Depth = dot size + ink weight only.

// MARK: - Primitives

struct ThinkingOrbDot {
    var x: CGFloat
    var y: CGFloat
    var z: CGFloat
    var r: CGFloat
    /// Ink value: 0 = darkest ink on paper. Mirrored on dark themes.
    var white: CGFloat
    var a: CGFloat
}

struct ThinkingOrbLine {
    var x1: CGFloat
    var y1: CGFloat
    var x2: CGFloat
    var y2: CGFloat
    var white: CGFloat
    var a: CGFloat
    var w: CGFloat
}

typealias ThinkingOrbProjector = (_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> (CGFloat, CGFloat, CGFloat)

enum ThinkingOrbMath {
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ f: CGFloat) -> CGFloat {
        a + (b - a) * f
    }

    static func frac(_ x: CGFloat) -> CGFloat {
        x - floor(x)
    }

    static func hashD(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let h = sin(a * 12.9898 + b * 78.233) * 43758.5453
        return h - floor(h)
    }

    static func vnoise(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
        let xi = floor(x)
        let yi = floor(y)
        var fx = x - xi
        var fy = y - yi
        fx = fx * fx * (3 - 2 * fx)
        fy = fy * fy * (3 - 2 * fy)
        let a = hashD(xi, yi)
        let b = hashD(xi + 1, yi)
        let c = hashD(xi, yi + 1)
        let d = hashD(xi + 1, yi + 1)
        return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy
    }

    static func fibDir(_ i: Int, _ n: Int) -> (CGFloat, CGFloat, CGFloat) {
        let golden = CGFloat.pi * (3 - sqrt(5))
        let y = 1 - (2 * (CGFloat(i) + 0.5)) / CGFloat(n)
        let rad = sqrt(max(0, 1 - y * y))
        let a = CGFloat(i) * golden
        return (rad * cos(a), y, rad * sin(a))
    }

    static func angleDelta(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        atan2(sin(a - b), cos(a - b))
    }

    static func makeProj(
        yaw: CGFloat,
        tilt: CGFloat,
        cx: CGFloat,
        cy: CGFloat,
        scale: CGFloat
    ) -> ThinkingOrbProjector {
        let st = sin(tilt)
        let ct = cos(tilt)
        let sy = sin(yaw)
        let cyw = cos(yaw)
        return { x, y, z in
            let x1 = x * cyw + z * sy
            let z1 = -x * sy + z * cyw
            let y1 = y * ct - z1 * st
            let z2 = y * st + z1 * ct
            return (cx + x1 * scale, cy - y1 * scale, z2)
        }
    }

    static func radiusScale(size: CGFloat, power: CGFloat) -> CGFloat {
        CGFloat(Darwin.pow(Double(size / 300), Double(power)))
    }
}

// MARK: - Mode options / presets

struct ThinkingOrbModeOpts: Sendable {
    var latRings: CGFloat? = nil
    var lonDensity: CGFloat? = nil
    var rings: CGFloat? = nil
    var lanes: CGFloat? = nil
    var segs: CGFloat? = nil
    var orbitN: CGFloat? = nil
    var ghostN: CGFloat? = nil
    var nodeN: CGFloat? = nil
    var strandN: CGFloat? = nil
    var signals: CGFloat? = nil
    var iconD: CGFloat? = nil
    var rBase: CGFloat? = nil
    var rDepth: CGFloat? = nil
    var rActive: CGFloat? = nil
    var rDot: CGFloat? = nil
    var ghostR: CGFloat? = nil
    var partR: CGFloat? = nil
    var partRDepth: CGFloat? = nil
    var nodeR: CGFloat? = nil
    var nodeRDepth: CGFloat? = nil
    var rSizeMul: CGFloat? = nil
    var rBoost: CGFloat? = nil
    var inkFar: CGFloat? = nil
    var inkSpan: CGFloat? = nil
    var rsPow: CGFloat? = nil
    var rMin: CGFloat? = nil
    var ghostA: CGFloat? = nil
    var particles: CGFloat? = nil
    var moveCount: CGFloat? = nil
    var thr: CGFloat? = nil
    var lineW: CGFloat? = nil
    var turns: CGFloat? = nil
    var faceOn: CGFloat? = nil
    var spin: CGFloat? = nil
    var bandMul: CGFloat? = nil
    var wobMul: CGFloat? = nil
    var scanMul: CGFloat? = nil
    var dimBase: CGFloat? = nil
    var spread: CGFloat? = nil

    static func scaleCounts(_ opts: ThinkingOrbModeOpts, scale: CGFloat) -> ThinkingOrbModeOpts {
        var out = opts
        let rt = sqrt(scale)

        func scalePair(_ a: inout CGFloat?, _ b: inout CGFloat?) {
            if let va = a, let vb = b {
                a = max(2, round(va * rt))
                b = max(2, round(vb * rt))
            }
        }
        scalePair(&out.latRings, &out.lonDensity)
        scalePair(&out.rings, &out.lonDensity)
        scalePair(&out.lanes, &out.segs)

        func scaleLinear(_ v: inout CGFloat?) {
            if let val = v, val != 0 {
                v = max(1, round(val * scale))
            }
        }
        scaleLinear(&out.orbitN)
        scaleLinear(&out.ghostN)
        scaleLinear(&out.nodeN)
        scaleLinear(&out.strandN)
        scaleLinear(&out.signals)

        if let v = out.iconD {
            out.iconD = max(0.02, v * scale)
        }
        return out
    }

    static func scaleRadii(_ opts: ThinkingOrbModeOpts, scale: CGFloat) -> ThinkingOrbModeOpts {
        var out = opts
        func mul(_ v: inout CGFloat?) {
            if let val = v { v = val * scale }
        }
        mul(&out.rBase)
        mul(&out.rDepth)
        mul(&out.rActive)
        mul(&out.rDot)
        mul(&out.ghostR)
        mul(&out.partR)
        mul(&out.partRDepth)
        mul(&out.nodeR)
        mul(&out.nodeRDepth)
        out.rSizeMul = (out.rSizeMul ?? 1) * scale
        return out
    }
}

enum ThinkingOrbModeKey: String {
    case orbits, globe, rubik, wave, web, braid, ribbon, ring, morph
}

enum ThinkingOrbPresets {
    static func mode(for state: ThinkingOrbState) -> ThinkingOrbModeKey {
        switch state {
        case .working: return .orbits
        case .searching: return .globe
        case .solving: return .rubik
        case .listening: return .wave
        case .connecting: return .web
        case .weaving: return .braid
        case .composing: return .ribbon
        case .breathing: return .ring
        case .shaping: return .morph
        }
    }

    static func baseProfile(_ mode: ThinkingOrbModeKey) -> ThinkingOrbModeOpts {
        switch mode {
        case .globe:
            return ThinkingOrbModeOpts(
                latRings: 17, lonDensity: 44,
                rBase: 0.6, rDepth: 1.7, rBoost: 1.0,
                inkFar: 0.62, inkSpan: 0.54, rsPow: 0.6, rMin: 0.3
            )
        case .orbits:
            // Field order must match ThinkingOrbModeOpts declaration.
            return ThinkingOrbModeOpts(
                orbitN: 12,
                ghostN: 40,
                ghostR: 0.9,
                partR: 1.2,
                partRDepth: 1.6,
                rsPow: 0.6,
                rMin: 0.3,
                ghostA: 0.5,
                particles: 3
            )
        case .rubik:
            return ThinkingOrbModeOpts(
                latRings: 15,
                lonDensity: 40,
                rBase: 0.6,
                rDepth: 1.7,
                rActive: 0.3,
                inkFar: 0.62,
                inkSpan: 0.54,
                rsPow: 0.6,
                rMin: 0.3,
                moveCount: 14
            )
        case .wave:
            return ThinkingOrbModeOpts(
                lonDensity: 40, rings: 15,
                rBase: 0.6, rDepth: 1.7, rsPow: 0.6, rMin: 0.3
            )
        case .web:
            return ThinkingOrbModeOpts(
                nodeN: 30, signals: 5,
                nodeR: 1.4, nodeRDepth: 1.8,
                rsPow: 0.6, rMin: 0.3, thr: 0.72, lineW: 0.8
            )
        case .braid:
            return ThinkingOrbModeOpts(
                ghostN: 150, strandN: 52,
                rBase: 1.2, rDepth: 1.8, rsPow: 0.6, rMin: 0.3, turns: 3.0
            )
        case .ribbon:
            return ThinkingOrbModeOpts(
                lanes: 5, segs: 88, ghostN: 150,
                rBase: 1.1, rDepth: 1.7, rsPow: 0.6, rMin: 0.3
            )
        case .ring:
            return ThinkingOrbModeOpts(
                lanes: 5, segs: 88, ghostN: 0,
                rBase: 1.1, rDepth: 1.7, rsPow: 0.6, rMin: 0.3, faceOn: 1
            )
        case .morph:
            return ThinkingOrbModeOpts(iconD: 1, rDot: 0.021, rMin: 0.25)
        }
    }

    struct Resolved: Sendable {
        let mode: ThinkingOrbModeKey
        let speed: CGFloat
        let opts: ThinkingOrbModeOpts
    }

    /// Resolve (state, size) to mode + fully scaled draw options.
    /// Size snaps to nearest of 20 / 64 for density baking.
    static func resolve(state: ThinkingOrbState, size: CGFloat) -> Resolved {
        let presetSize: CGFloat = abs(size - 20) <= abs(size - 64) ? 20 : 64
        let mode = mode(for: state)
        let (speed, count, sizeMul, extra) = preset(mode: mode, size: presetSize)

        var opts = baseProfile(mode)
        if count != 1 { opts = ThinkingOrbModeOpts.scaleCounts(opts, scale: count) }
        if sizeMul != 1 { opts = ThinkingOrbModeOpts.scaleRadii(opts, scale: sizeMul) }
        if let extra {
            opts = merge(opts, extra)
        }
        return Resolved(mode: mode, speed: speed, opts: opts)
    }

    private static func merge(_ base: ThinkingOrbModeOpts, _ extra: ThinkingOrbModeOpts) -> ThinkingOrbModeOpts {
        var o = base
        if let v = extra.scanMul { o.scanMul = v }
        if let v = extra.dimBase { o.dimBase = v }
        if let v = extra.spin { o.spin = v }
        if let v = extra.bandMul { o.bandMul = v }
        if let v = extra.wobMul { o.wobMul = v }
        if let v = extra.spread { o.spread = v }
        if let v = extra.faceOn { o.faceOn = v }
        return o
    }

    private static func preset(
        mode: ThinkingOrbModeKey,
        size: CGFloat
    ) -> (speed: CGFloat, count: CGFloat, size: CGFloat, extra: ThinkingOrbModeOpts?) {
        let isSmall = size <= 32
        switch mode {
        case .orbits:
            return isSmall
                ? (3.9, 0.238, 2.4, nil)
                : (1.885, 1, 1, nil)
        case .globe:
            return isSmall
                ? (2.665, 0.105, 1.75, ThinkingOrbModeOpts(scanMul: 4.335, dimBase: 0.45))
                : (2.015, 0.42, 1.15, ThinkingOrbModeOpts(scanMul: 4.08, dimBase: 0.45))
        case .rubik:
            return isSmall
                ? (1.95, 0.088, 1.9, nil)
                : (1.82, 0.35, 1.05, nil)
        case .wave:
            return isSmall
                ? (3.998, 0.105, 1.6, nil)
                : (4.388, 0.341, 1, nil)
        case .web:
            return isSmall
                ? (6.63, 0.25, 1.52, nil)
                : (3.315, 1.35, 0.95, nil)
        case .braid:
            return isSmall
                ? (2.75, 0.1125, 1.36, nil)
                : (1.625, 0.5, 1, nil)
        case .ribbon:
            return isSmall
                ? (3.12, 0.051, 1.073, ThinkingOrbModeOpts(spin: 0, bandMul: 4.94, wobMul: 1))
                : (2.34, 0.25, 0.85, ThinkingOrbModeOpts(spin: 0, bandMul: 3.9, wobMul: 1))
        case .ring:
            return isSmall
                ? (3.78, 0.028, 1.622, ThinkingOrbModeOpts(spin: 0, bandMul: 3.968, wobMul: 0.565))
                : (3.24, 0.25, 0.956, ThinkingOrbModeOpts(spin: 0, bandMul: 3.627, wobMul: 0.368))
        case .morph:
            return isSmall
                ? (2.08, 0.53, 1.011, ThinkingOrbModeOpts(spread: 1.45))
                : (2.405, 0.702, 0.395, ThinkingOrbModeOpts(spread: 1.45))
        }
    }
}

// MARK: - Paint into GraphicsContext

enum ThinkingOrbPaint {
    static func paint(
        _ context: GraphicsContext,
        dots: inout [ThinkingOrbDot],
        dark: Bool,
        rMin: CGFloat
    ) {
        dots.sort { $0.z < $1.z }
        for d in dots {
            let alpha = d.a
            if alpha < 0.02 { continue }
            let w = min(1, max(0, d.white))
            let g = dark ? (1 - w) : w
            let r = max(rMin, d.r)
            let rect = CGRect(x: d.x - r, y: d.y - r, width: r * 2, height: r * 2)
            context.fill(
                Path(ellipseIn: rect),
                with: .color(Color(white: Double(g), opacity: Double(alpha)))
            )
        }
    }

    static func paintLines(
        _ context: GraphicsContext,
        lines: [ThinkingOrbLine],
        dark: Bool
    ) {
        for l in lines {
            let alpha = l.a
            if alpha < 0.02 { continue }
            let w = min(1, max(0, l.white))
            let g = dark ? (1 - w) : w
            var path = Path()
            path.move(to: CGPoint(x: l.x1, y: l.y1))
            path.addLine(to: CGPoint(x: l.x2, y: l.y2))
            context.stroke(
                path,
                with: .color(Color(white: Double(g), opacity: Double(alpha))),
                lineWidth: l.w
            )
        }
    }
}

// MARK: - Mode drawers

enum ThinkingOrbModes {
    static func draw(
        mode: ThinkingOrbModeKey,
        context: GraphicsContext,
        size: CGFloat,
        t: CGFloat,
        dark: Bool,
        opts: ThinkingOrbModeOpts
    ) {
        switch mode {
        case .orbits: drawOrbits(context, size, t, dark, opts)
        case .globe: drawGlobe(context, size, t, dark, opts)
        case .rubik: drawRubik(context, size, t, dark, opts)
        case .wave: drawWave(context, size, t, dark, opts)
        case .web: drawWeb(context, size, t, dark, opts)
        case .braid: drawBraid(context, size, t, dark, opts)
        case .ribbon, .ring: drawRibbon(context, size, t, dark, opts)
        case .morph: drawMorph(context, size, t, dark, opts)
        }
    }

    // MARK: Orbits (working)

    private static func drawOrbits(
        _ ctx: GraphicsContext, _ size: CGFloat, _ t: CGFloat, _ dark: Bool, _ o: ThinkingOrbModeOpts
    ) {
        let cx = size / 2
        let cy = size / 2
        let R = (size / 2) * 0.82
        let pt = ThinkingOrbMath.makeProj(yaw: t * 0.12, tilt: 0.3, cx: cx, cy: cy, scale: 1)
        let rs = ThinkingOrbMath.radiusScale(size: size, power: o.rsPow ?? 0.6)
        var dots: [ThinkingOrbDot] = []
        let orbitN = Int(o.orbitN ?? 12)
        let ghostN = Int(o.ghostN ?? 40)
        let particles = Int(o.particles ?? 3)

        for orb in 0..<orbitN {
            let h1 = ThinkingOrbMath.hashD(CGFloat(orb), 1.7)
            let h2 = ThinkingOrbMath.hashD(CGFloat(orb), 5.2)
            let h3 = ThinkingOrbMath.hashD(CGFloat(orb), 8.9)
            let ro = R * (0.45 + 0.52 * h1)
            let th = h1 * 2 * .pi
            let phi = acos(2 * h2 - 1)
            let nx = sin(phi) * cos(th)
            let ny = cos(phi)
            let nz = sin(phi) * sin(th)
            var ux = -ny
            var uy = nx
            let uz: CGFloat = 0
            let ul = max(1e-6, sqrt(ux * ux + uy * uy))
            ux /= ul
            uy /= ul
            let vx = ny * uz - nz * uy
            let vy = nz * ux - nx * uz
            let vz = nx * uy - ny * ux
            let speed = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1)

            for k in 0..<ghostN {
                let a = (CGFloat(k) / CGFloat(ghostN)) * 2 * .pi
                let (px, py, z) = pt(
                    (ux * cos(a) + vx * sin(a)) * ro,
                    (uy * cos(a) + vy * sin(a)) * ro,
                    (uz * cos(a) + vz * sin(a)) * ro
                )
                let depth = (z / ro + 1) / 2
                dots.append(ThinkingOrbDot(
                    x: px, y: py, z: z,
                    r: (o.ghostR ?? 0.9) * rs,
                    white: 0.72,
                    a: (o.ghostA ?? 0.5) * (0.4 + 0.6 * depth)
                ))
            }
            for m in 0..<particles {
                let a = t * speed + (CGFloat(m) / CGFloat(particles)) * 2 * .pi + h2 * 6
                let (px, py, z) = pt(
                    (ux * cos(a) + vx * sin(a)) * ro,
                    (uy * cos(a) + vy * sin(a)) * ro,
                    (uz * cos(a) + vz * sin(a)) * ro
                )
                let depth = (z / ro + 1) / 2
                dots.append(ThinkingOrbDot(
                    x: px, y: py, z: z,
                    r: ((o.partR ?? 1.2) + (o.partRDepth ?? 1.6) * depth) * rs,
                    white: 0.3 - 0.22 * depth,
                    a: 1
                ))
            }
        }
        ThinkingOrbPaint.paint(ctx, dots: &dots, dark: dark, rMin: o.rMin ?? 0.3)
    }

    // MARK: Globe (searching)

    private static func drawGlobe(
        _ ctx: GraphicsContext, _ size: CGFloat, _ t: CGFloat, _ dark: Bool, _ o: ThinkingOrbModeOpts
    ) {
        let spin: CGFloat = 0.5
        let cx = size / 2
        let cy = size / 2
        let radius = (size / 2) * 0.82
        let tilt = 0.4 + 0.06 * sin(t * 0.35)
        let pt = ThinkingOrbMath.makeProj(yaw: t * spin, tilt: tilt, cx: cx, cy: cy, scale: radius)
        let scan = t * (spin + (1.7 - spin) * (o.scanMul ?? 1))
        let rs = ThinkingOrbMath.radiusScale(size: size, power: o.rsPow ?? 0.6)
        let dimBase = o.dimBase ?? 1
        var dots: [ThinkingOrbDot] = []
        let latRings = Int(o.latRings ?? 17)
        let lonDensity = o.lonDensity ?? 44

        for li in 0...latRings {
            let lat = -.pi / 2 + (CGFloat(li) / CGFloat(latRings)) * .pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let lonCount = max(1, Int(round(abs(cosLat) * lonDensity)))
            for lj in 0..<lonCount {
                let lon = (CGFloat(lj) / CGFloat(lonCount)) * 2 * .pi
                let (px, py, z) = pt(cosLat * cos(lon), sinLat, cosLat * sin(lon))
                let depth = (z + 1) / 2
                let d = ThinkingOrbMath.angleDelta(lon + t * spin, scan)
                let boost = exp(-(d * d) / 0.18) * max(0, z)
                dots.append(ThinkingOrbDot(
                    x: px, y: py, z: z,
                    r: ((o.rBase ?? 0.6) + (o.rDepth ?? 1.7) * depth + (o.rBoost ?? 1) * boost) * rs,
                    white: (o.inkFar ?? 0.62) - (o.inkSpan ?? 0.54) * depth,
                    a: dimBase + (1 - dimBase) * min(1, boost)
                ))
            }
        }
        ThinkingOrbPaint.paint(ctx, dots: &dots, dark: dark, rMin: o.rMin ?? 0.3)
    }

    // MARK: Rubik (solving)

    private struct RubikMove {
        var axis: Int
        var lo: CGFloat
        var hi: CGFloat
        var ang: CGFloat
    }

    private static func makeMoves(_ count: Int) -> [RubikMove] {
        (0..<count).map { i in
            let axis = min(2, Int(floor(ThinkingOrbMath.hashD(CGFloat(i), 2.3) * 3)))
            let lo = -1.0 + 0.5 * CGFloat(min(3, Int(floor(ThinkingOrbMath.hashD(CGFloat(i), 5.9) * 4))))
            let dir: CGFloat = ThinkingOrbMath.hashD(CGFloat(i), 7.7) < 0.5 ? 1 : -1
            return RubikMove(axis: axis, lo: lo, hi: lo + 0.5, ang: dir * .pi / 2)
        }
    }

    private static func solveCycle(time: CGFloat, count: Int, slotDur: CGFloat, rest: CGFloat)
        -> (amount: [CGFloat], active: Int)
    {
        let cyc = 2 * CGFloat(count) * slotDur + rest
        let tc = time.truncatingRemainder(dividingBy: cyc)
        var amount = [CGFloat](repeating: 0, count: count)
        var active = -1
        if tc < 2 * CGFloat(count) * slotDur {
            let slot = Int(floor(tc / slotDur))
            let p = (tc - CGFloat(slot) * slotDur) / slotDur
            let cl = min(1, p / 0.7)
            let ep = 1 - CGFloat(Darwin.pow(Double(1 - cl), 3))
            if slot < count {
                for i in 0..<slot { amount[i] = 1 }
                amount[slot] = ep
                active = slot
            } else {
                let u = 2 * count - 1 - slot
                for i in 0..<u { amount[i] = 1 }
                amount[u] = 1 - ep
                active = u
            }
        }
        return (amount, active)
    }

    private static func applyMoves(
        _ pt3: (CGFloat, CGFloat, CGFloat),
        _ moves: [RubikMove],
        _ sc: (amount: [CGFloat], active: Int)
    ) -> (CGFloat, CGFloat, CGFloat, Bool) {
        var x = pt3.0, y = pt3.1, z = pt3.2
        var inActive = false
        for i in 0..<moves.count {
            if sc.amount[i] <= 0 { continue }
            let mv = moves[i]
            let coord = mv.axis == 0 ? x : (mv.axis == 1 ? y : z)
            if coord < mv.lo || coord >= mv.hi { continue }
            if i == sc.active { inActive = true }
            let a = mv.ang * sc.amount[i]
            let ca = cos(a)
            let sa = sin(a)
            if mv.axis == 0 {
                let y2 = y * ca - z * sa
                z = y * sa + z * ca
                y = y2
            } else if mv.axis == 1 {
                let x2 = x * ca + z * sa
                z = -x * sa + z * ca
                x = x2
            } else {
                let x2 = x * ca - y * sa
                y = x * sa + y * ca
                x = x2
            }
        }
        return (x, y, z, inActive)
    }

    private static func drawRubik(
        _ ctx: GraphicsContext, _ size: CGFloat, _ t: CGFloat, _ dark: Bool, _ o: ThinkingOrbModeOpts
    ) {
        let cx = size / 2
        let cy = size / 2
        let R = (size / 2) * 0.82
        let pt = ThinkingOrbMath.makeProj(
            yaw: t * 0.55,
            tilt: 0.35 + 0.1 * sin(t * 0.9),
            cx: cx, cy: cy, scale: R
        )
        let rs = ThinkingOrbMath.radiusScale(size: size, power: o.rsPow ?? 0.6)
        let moveCount = Int(o.moveCount ?? 14)
        let moves = makeMoves(moveCount)
        let sc = solveCycle(time: t, count: moveCount, slotDur: 0.42, rest: 1.2)
        var dots: [ThinkingOrbDot] = []
        let latRings = Int(o.latRings ?? 15)
        let lonDensity = o.lonDensity ?? 40

        for li in 0...latRings {
            let lat = -.pi / 2 + (CGFloat(li) / CGFloat(latRings)) * .pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let lonCount = max(1, Int(round(abs(cosLat) * lonDensity)))
            for lj in 0..<lonCount {
                let lon = (CGFloat(lj) / CGFloat(lonCount)) * 2 * .pi
                let (x, y, z, inActive) = applyMoves(
                    (cosLat * cos(lon), sinLat, cosLat * sin(lon)), moves, sc
                )
                let (px, py, zr) = pt(x, y, z)
                let depth = (zr + 1) / 2
                dots.append(ThinkingOrbDot(
                    x: px, y: py, z: zr,
                    r: ((o.rBase ?? 0.6) + (o.rDepth ?? 1.7) * depth + (inActive ? (o.rActive ?? 0.3) : 0)) * rs,
                    white: (o.inkFar ?? 0.62) - (o.inkSpan ?? 0.54) * depth - (inActive ? 0.14 : 0),
                    a: 1
                ))
            }
        }
        ThinkingOrbPaint.paint(ctx, dots: &dots, dark: dark, rMin: o.rMin ?? 0.3)
    }

    // MARK: Wave (listening)

    private static func drawWave(
        _ ctx: GraphicsContext, _ size: CGFloat, _ t: CGFloat, _ dark: Bool, _ o: ThinkingOrbModeOpts
    ) {
        let cx = size / 2
        let cy = size / 2
        let R = (size / 2) * 0.874
        let pt = ThinkingOrbMath.makeProj(yaw: t * 0.18, tilt: 0.38, cx: cx, cy: cy, scale: 1)
        let rs = ThinkingOrbMath.radiusScale(size: size, power: o.rsPow ?? 0.6)
        var dots: [ThinkingOrbDot] = []
        let rings = Int(o.rings ?? 15)
        let lonDensity = o.lonDensity ?? 40

        for ri in 0...rings {
            let lat = -.pi / 2 + (CGFloat(ri) / CGFloat(rings)) * .pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let w = 0.62 * sin(t * 2.1 - CGFloat(ri) * 0.52)
                + 0.38 * sin(t * 1.27 + CGFloat(ri) * 0.83)
            let rr = R * (0.88 + 0.105 * w)
            let lonCount = max(1, Int(round(abs(cosLat) * lonDensity)))
            for lj in 0..<lonCount {
                let lon = (CGFloat(lj) / CGFloat(lonCount)) * 2 * .pi
                let (px, py, z) = pt(
                    cosLat * cos(lon) * rr,
                    sinLat * rr,
                    cosLat * sin(lon) * rr
                )
                let depth = (z / R + 1) / 2
                let crest = max(0, w)
                dots.append(ThinkingOrbDot(
                    x: px, y: py, z: z,
                    r: ((o.rBase ?? 0.6) + (o.rDepth ?? 1.7) * depth) * (1 + 0.4 * crest) * rs,
                    white: 0.66 - 0.56 * depth - 0.1 * crest,
                    a: 1
                ))
            }
        }
        ThinkingOrbPaint.paint(ctx, dots: &dots, dark: dark, rMin: o.rMin ?? 0.3)
    }

    // MARK: Web (connecting)

    private static func drawWeb(
        _ ctx: GraphicsContext, _ size: CGFloat, _ t: CGFloat, _ dark: Bool, _ o: ThinkingOrbModeOpts
    ) {
        let cx = size / 2
        let cy = size / 2
        let R = (size / 2) * 0.8 * (o.spread ?? 1)
        let pt = ThinkingOrbMath.makeProj(yaw: t * 0.12, tilt: 0.32, cx: cx, cy: cy, scale: R)
        let rs = ThinkingOrbMath.radiusScale(size: size, power: o.rsPow ?? 0.6)
        let nodeN = Int(o.nodeN ?? 30)
        let thr = o.thr ?? 0.72
        let nodeR = o.nodeR ?? 1.4
        let nodeRDepth = o.nodeRDepth ?? 1.8

        var nodes: [(CGFloat, CGFloat, CGFloat)] = []
        nodes.reserveCapacity(nodeN)
        for i in 0..<nodeN {
            let d = ThinkingOrbMath.fibDir(i, nodeN)
            let x = d.0 + 0.3 * (ThinkingOrbMath.vnoise(CGFloat(i) * 0.31 + 9, t * 0.24) - 0.5) * 2
            let y = d.1 + 0.3 * (ThinkingOrbMath.vnoise(CGFloat(i) * 0.53 + 27, t * 0.21) - 0.5) * 2
            let z = d.2 + 0.3 * (ThinkingOrbMath.vnoise(CGFloat(i) * 0.77 + 55, t * 0.27) - 0.5) * 2
            let l = sqrt(x * x + y * y + z * z)
            nodes.append((x / l, y / l, z / l))
        }

        var lines: [ThinkingOrbLine] = []
        var dots: [ThinkingOrbDot] = []

        for i in 0..<nodeN {
            for j in (i + 1)..<nodeN {
                let dx = nodes[i].0 - nodes[j].0
                let dy = nodes[i].1 - nodes[j].1
                let dz = nodes[i].2 - nodes[j].2
                let dist = sqrt(dx * dx + dy * dy + dz * dz)
                if dist >= thr { continue }
                let (x1, y1, z1) = pt(nodes[i].0, nodes[i].1, nodes[i].2)
                let (x2, y2, z2) = pt(nodes[j].0, nodes[j].1, nodes[j].2)
                let depth = ((z1 + z2) / 2 + 1) / 2
                lines.append(ThinkingOrbLine(
                    x1: x1, y1: y1, x2: x2, y2: y2,
                    white: 0.42,
                    a: (1 - dist / thr) * (0.3 + 0.55 * depth),
                    w: max(0.6, (o.lineW ?? 0.8) * rs)
                ))
            }
        }

        for i in 0..<nodeN {
            let (px, py, z) = pt(nodes[i].0, nodes[i].1, nodes[i].2)
            let depth = (z + 1) / 2
            let pulse = 1 + 0.25 * sin(t * 1.4 + CGFloat(i) * 2.7)
            dots.append(ThinkingOrbDot(
                x: px, y: py, z: z,
                r: (nodeR + nodeRDepth * depth) * pulse * rs,
                white: 0.55 - 0.45 * depth,
                a: 1
            ))
        }

        let signals = Int(o.signals ?? 5)
        for s in 0..<signals {
            let seg = Int(floor(t * 0.55 + CGFloat(s) * 7.31))
            let a = Int(floor(ThinkingOrbMath.hashD(CGFloat(seg), CGFloat(s) * 3.1 + 1.7) * CGFloat(nodeN)))
            let b = Int(floor(ThinkingOrbMath.hashD(CGFloat(seg), CGFloat(s) * 5.7 + 4.2) * CGFloat(nodeN)))
            if a == b { continue }
            let f = ThinkingOrbMath.frac(t * 0.55 + CGFloat(s) * 7.31)
            let x = ThinkingOrbMath.lerp(nodes[a].0, nodes[b].0, f)
            let y = ThinkingOrbMath.lerp(nodes[a].1, nodes[b].1, f)
            let z = ThinkingOrbMath.lerp(nodes[a].2, nodes[b].2, f)
            let l = max(1e-6, sqrt(x * x + y * y + z * z))
            let (px, py, zr) = pt(x / l, y / l, z / l)
            let depth = (zr + 1) / 2
            dots.append(ThinkingOrbDot(
                x: px, y: py, z: zr,
                r: (nodeR * 1.5 + nodeRDepth * depth) * rs,
                white: 0.05,
                a: 0.5 + 0.5 * depth
            ))
        }

        ThinkingOrbPaint.paintLines(ctx, lines: lines, dark: dark)
        ThinkingOrbPaint.paint(ctx, dots: &dots, dark: dark, rMin: o.rMin ?? 0.3)
    }

    // MARK: Braid (weaving)

    private static func drawBraid(
        _ ctx: GraphicsContext, _ size: CGFloat, _ t: CGFloat, _ dark: Bool, _ o: ThinkingOrbModeOpts
    ) {
        let cx = size / 2
        let cy = size / 2
        let R = (size / 2) * 0.76
        let pt = ThinkingOrbMath.makeProj(yaw: t * 0.4, tilt: 0.3, cx: cx, cy: cy, scale: 1)
        let rs = ThinkingOrbMath.radiusScale(size: size, power: o.rsPow ?? 0.6)
        var dots: [ThinkingOrbDot] = []
        let ghostN = Int(o.ghostN ?? 150)

        for i in 0..<ghostN {
            let d = ThinkingOrbMath.fibDir(i, ghostN)
            let (px, py, z) = pt(d.0 * R, d.1 * R, d.2 * R)
            let depth = (z / R + 1) / 2
            dots.append(ThinkingOrbDot(
                x: px, y: py, z: z, r: 0.8 * rs, white: 0.78, a: 0.1 + 0.22 * depth
            ))
        }

        let strandN = Int(o.strandN ?? 52)
        let turns = o.turns ?? 3
        for s in 0..<3 {
            let phase = (CGFloat(s) / 3) * 2 * .pi
            for i in 0..<strandN {
                let u = (ThinkingOrbMath.frac(CGFloat(i) / CGFloat(strandN) + t * 0.045) * 2 - 1) * 0.96
                let surf = sqrt(max(0, 1 - u * u))
                let endFade = min(1, (1 - abs(u)) / 0.1)
                let a = u * .pi * turns + phase
                let weave = 1 + 0.075 * sin(u * .pi * turns * 2 + phase * 2 + t * 0.8)
                let rr = surf * R * weave
                let (px, py, zr) = pt(cos(a) * rr, u * R * weave, sin(a) * rr)
                let depth = (zr / R + 1) / 2
                dots.append(ThinkingOrbDot(
                    x: px, y: py, z: zr,
                    r: ((o.rBase ?? 1.2) + (o.rDepth ?? 1.8) * depth) * rs,
                    white: 0.55 - 0.45 * depth,
                    a: endFade * (0.45 + 0.55 * depth)
                ))
            }
        }
        ThinkingOrbPaint.paint(ctx, dots: &dots, dark: dark, rMin: o.rMin ?? 0.3)
    }

    // MARK: Ribbon / ring (composing / breathing)

    private static func drawRibbon(
        _ ctx: GraphicsContext, _ size: CGFloat, _ t: CGFloat, _ dark: Bool, _ o: ThinkingOrbModeOpts
    ) {
        let cx = size / 2
        let cy = size / 2
        let R = (size / 2) * 0.78
        let spin = o.spin ?? 1
        let camTilt: CGFloat = 0.3
        let pt = ThinkingOrbMath.makeProj(yaw: t * 0.1 * spin, tilt: camTilt, cx: cx, cy: cy, scale: 1)
        let rs = ThinkingOrbMath.radiusScale(size: size, power: o.rsPow ?? 0.6)
        let faceOn = (o.faceOn ?? 0) != 0
        var dots: [ThinkingOrbDot] = []
        let ghostN = Int(o.ghostN ?? 150)

        for i in 0..<ghostN {
            let d = ThinkingOrbMath.fibDir(i, ghostN)
            let (px, py, z) = pt(d.0 * R, d.1 * R, d.2 * R)
            let depth = (z / R + 1) / 2
            dots.append(ThinkingOrbDot(
                x: px, y: py, z: z, r: 0.8 * rs, white: 0.78, a: 0.1 + 0.22 * depth
            ))
        }

        let ya = t * 0.24 * spin
        let ta: CGFloat = faceOn ? -camTilt : 0.55 + 0.3 * sin(t * 0.18) * spin
        let ux = cos(ya)
        let uy: CGFloat = 0
        let uz = sin(ya)
        let vx = -uz * sin(ta)
        let vy = cos(ta)
        let vz = ux * sin(ta)
        let nx = uy * vz - uz * vy
        let ny = uz * vx - ux * vz
        let nz = ux * vy - uy * vx

        let wobAmp = 0.23 * (o.wobMul ?? 1)
        let baseR = faceOn ? R / (1 + 0.85 * wobAmp) : R
        let baseLanes = o.lanes ?? 5
        let segs = Int(o.segs ?? 88)
        let lanes = max(1, Int(round(baseLanes * (o.bandMul ?? 1))))

        for w in 0..<lanes {
            let laneOff = (CGFloat(w) - CGFloat(lanes - 1) / 2) * 0.075
            let edge = abs(CGFloat(w) - CGFloat(lanes - 1) / 2) / max(1, CGFloat(lanes - 1) / 2)
            for k in 0..<segs {
                let a = (CGFloat(k) / CGFloat(segs)) * 2 * .pi
                let wob = (
                    0.16 * sin(a * 3 - t * 1.7 + CGFloat(w) * 0.22)
                        + 0.07 * sin(a * 5 + t * 1.1)
                ) * (o.wobMul ?? 1)
                let radial: CGFloat = faceOn ? 1 + wob : 1
                let off = faceOn ? laneOff : laneOff + wob
                let x = ux * cos(a) + vx * sin(a) + nx * off
                let y = uy * cos(a) + vy * sin(a) + ny * off
                let z = uz * cos(a) + vz * sin(a) + nz * off
                let l = sqrt(x * x + y * y + z * z)
                let rr = baseR * radial
                let (px, py, zr) = pt((x / l) * rr, (y / l) * rr, (z / l) * rr)
                let depth = (zr / R + 1) / 2
                dots.append(ThinkingOrbDot(
                    x: px, y: py, z: zr,
                    r: ((o.rBase ?? 1.1) + (o.rDepth ?? 1.7) * depth) * (1 - 0.25 * edge) * rs,
                    white: 0.52 - 0.44 * depth + 0.18 * edge,
                    a: 0.4 + 0.6 * depth
                ))
            }
        }
        ThinkingOrbPaint.paint(ctx, dots: &dots, dark: dark, rMin: o.rMin ?? 0.3)
    }

    // MARK: Morph (shaping)

    private static func smoothE(_ x: CGFloat) -> CGFloat {
        x * x * (3 - 2 * x)
    }

    private static func polyPath(_ verts: [(CGFloat, CGFloat)]) -> (CGFloat) -> (CGFloat, CGFloat) {
        let V = verts.count
        var L: [CGFloat] = []
        var total: CGFloat = 0
        for i in 0..<V {
            let a = verts[i]
            let b = verts[(i + 1) % V]
            let l = hypot(b.0 - a.0, b.1 - a.1)
            L.append(l)
            total += l
        }
        return { f in
            var target = f * total
            var i = 0
            while target > L[i] && i < V - 1 {
                target -= L[i]
                i += 1
            }
            let a = verts[i]
            let b = verts[(i + 1) % V]
            let ff = L[i] > 0 ? min(1, target / L[i]) : 0
            return (a.0 + (b.0 - a.0) * ff, a.1 + (b.1 - a.1) * ff)
        }
    }

    private static func circlePath(_ f: CGFloat) -> (CGFloat, CGFloat) {
        let a = -.pi / 2 + f * 2 * .pi
        return (cos(a) * 0.24, sin(a) * 0.24)
    }

    private static func morphN(_ d: CGFloat) -> Int {
        max(6, Int(round(34 * d)))
    }

    private static func drawMorph(
        _ ctx: GraphicsContext, _ size: CGFloat, _ t: CGFloat, _ dark: Bool, _ o: ThinkingOrbModeOpts
    ) {
        let hold: CGFloat = 1.4
        let morph: CGFloat = 0.9
        let seg = hold + morph
        let triangle = polyPath([(0.0, -0.26), (0.24, 0.16), (-0.24, 0.16)])
        let square = polyPath([
            (0, -0.2), (0.2, -0.2), (0.2, 0.2), (-0.2, 0.2), (-0.2, -0.2)
        ])
        let cycle: [(CGFloat) -> (CGFloat, CGFloat)] = [circlePath, triangle, square]
        let K = cycle.count
        let tc = t.truncatingRemainder(dividingBy: seg * CGFloat(K))
        let k = Int(floor(tc / seg))
        let local = tc - CGFloat(k) * seg
        let m = local > hold ? smoothE((local - hold) / morph) : 0
        let sprd = o.spread ?? 1

        let pA = cycle[k]
        let pB = cycle[(k + 1) % K]
        let M = 160
        var pts: [(CGFloat, CGFloat)] = []
        pts.reserveCapacity(M)
        for i in 0..<M {
            let f = CGFloat(i) / CGFloat(M)
            let a = pA(f)
            let b = pB(f)
            pts.append(((a.0 + (b.0 - a.0) * m) * sprd, (a.1 + (b.1 - a.1) * m) * sprd))
        }
        var L: [CGFloat] = []
        var total: CGFloat = 0
        for i in 0..<M {
            let a = pts[i]
            let b = pts[(i + 1) % M]
            let l = hypot(b.0 - a.0, b.1 - a.1)
            L.append(l)
            total += l
        }

        let n = morphN(o.iconD ?? 1)
        let re = (o.rDot ?? 0.021) * 1.35 * sprd
        let pulse = 1 + 0.02 * sin(local * 3.1)
        var dots: [ThinkingOrbDot] = []
        let c2 = size / 2
        var segIdx = 0
        var acc: CGFloat = 0
        for k2 in 0..<n {
            let target = (CGFloat(k2) / CGFloat(n)) * total
            while acc + L[segIdx] < target && segIdx < M - 1 {
                acc += L[segIdx]
                segIdx += 1
            }
            let a = pts[segIdx]
            let b = pts[(segIdx + 1) % M]
            let f = L[segIdx] > 0 ? min(1, (target - acc) / L[segIdx]) : 0
            let x = (a.0 + (b.0 - a.0) * f) * pulse
            let y = (a.1 + (b.1 - a.1) * f) * pulse
            dots.append(ThinkingOrbDot(
                x: c2 + x * size,
                y: c2 + y * size,
                z: 0,
                r: max(0.35, re * size),
                white: 0.1,
                a: 1
            ))
        }
        ThinkingOrbPaint.paint(ctx, dots: &dots, dark: dark, rMin: o.rMin ?? 0.25)
    }
}
