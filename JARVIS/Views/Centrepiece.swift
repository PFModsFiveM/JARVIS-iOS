import SwiftUI

/// The home screen's centrepiece: the circle or the face, both reacting to what JARVIS is doing. Tap to switch.
struct CentrepieceView: View {
    let kind: Centrepiece
    let state: JarvisVisualState
    /// 0-1: the microphone while listening, JARVIS's own voice while speaking.
    let level: @MainActor () -> Float
    /// The mouth frames heard since the last call while JARVIS speaks; nil when nothing is playing.
    let mouth: @MainActor () -> [MouthFrame]?
    var facialState = true

    var body: some View {
        switch kind {
        case .circle:
            CoreView(state: state, level: level)
        case .face:
            FaceView(state: state, level: level, mouth: mouth, facialState: facialState)
        case .none:
            EmptyView()
        }
    }
}

// MARK: - the face

/// The holographic head, painted at up to 30 frames a second while on screen and not at all while off it.
struct FaceView: View {
    let state: JarvisVisualState
    let level: @MainActor () -> Float
    let mouth: @MainActor () -> [MouthFrame]?
    let facialState: Bool

    @StateObject private var engine = FaceEngine()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            if let image = engine.frame(at: timeline.date, state: state, level: level(), mouth: mouth(), facialState: facialState) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(1, contentMode: .fit)
            } else {
                CoreView(state: state, level: level)
            }
        }
    }
}

/// Holds the animator and renderer across frames; SwiftUI views are rebuilt, this is not.
final class FaceEngine: ObservableObject {
    /// Pixels a side. The PC paints 320-640; beyond this the wire reads no finer on a phone.
    static let surface = 360

    private let animator: FaceAnimator?
    private let renderer: FaceRenderer?
    private var last: Date?

    init() {
        if let mesh = HeadMesh.shared {
            animator = FaceAnimator(mesh: mesh)
            renderer = FaceRenderer(mesh: mesh, size: Self.surface)
        } else {
            animator = nil
            renderer = nil
        }
    }

    func frame(at date: Date, state: JarvisVisualState, level: Float, mouth: [MouthFrame]?, facialState: Bool) -> CGImage? {
        guard let animator, let renderer else { return nil }
        let dt = Float(last.map { date.timeIntervalSince($0) } ?? 0.033)
        last = date
        animator.step(dt: dt, amp: level, mood: state.mood(facialState: facialState), schedule: state == .speaking ? mouth : nil)
        let (vertices, normals) = animator.poseGeometry()
        return renderer.paint(pose: animator.pose, vertices: vertices, normals: normals, primary: state.appearance.accent)
    }
}

// MARK: - the circle

/// The JARVIS core: layered concentric rings, each turning at its own speed and direction around a pulsing centre,
/// which recolours and changes tempo with the state and swells with the voice. The PC's `JarvisCore`, drawn in a
/// 400-unit square scaled to fit.
struct CoreView: View {
    let state: JarvisVisualState
    let level: @MainActor () -> Float

    @StateObject private var engine = CoreEngine()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let heard = level()
            let engine = self.engine
            let state = self.state
            Canvas { context, size in
                engine.advance(to: timeline.date, state: state, level: heard)
                engine.draw(in: &context, size: size, state: state)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

final class CoreEngine: ObservableObject {
    enum Style { case arcs, ticks, blocks, dots, dashed }

    struct Ring {
        let style: Style
        let radius: Double
        let thickness: Double
        let rpm: Double
        var weight = 1
        var accent = false
        var segments: [(Double, Double)] = []
        var count = 0
        var pulse = false
    }

    static let rings: [Ring] = [
        Ring(style: .dashed, radius: 192, thickness: 1.0, rpm: 0.6, weight: 0),
        Ring(style: .dots, radius: 181, thickness: 2.2, rpm: 1.4, weight: 1),
        Ring(style: .arcs, radius: 170, thickness: 5.0, rpm: -2.4, weight: 2, segments: [(18, 96), (140, 54), (212, 108)]),
        Ring(style: .arcs, radius: 170, thickness: 5.0, rpm: -2.4, weight: 2, accent: true, segments: [(336, 30)]),
        Ring(style: .ticks, radius: 157, thickness: 1.4, rpm: 1.0, weight: 0, count: 84),
        Ring(style: .blocks, radius: 143, thickness: 5.0, rpm: -3.8, weight: 1, count: 26, pulse: true),
        Ring(style: .arcs, radius: 130, thickness: 3.0, rpm: 4.6, weight: 2, segments: [(300, 84), (40, 44), (100, 58), (176, 76)]),
        Ring(style: .dashed, radius: 117, thickness: 1.0, rpm: -6.0, weight: 0),
        Ring(style: .arcs, radius: 103, thickness: 2.5, rpm: 7.2, weight: 2, segments: [(250, 70), (25, 58), (120, 62)]),
        Ring(style: .ticks, radius: 88, thickness: 1.2, rpm: -8.5, weight: 0, count: 48, pulse: true),
    ]

    /// Angles and phases are integrated, not computed from the clock, so a change of tempo never makes a ring jump.
    private var angles = [Double](repeating: 0, count: CoreEngine.rings.count)
    private var sweep = 0.0, reticle = 0.0, iris = 0.0
    private var phase = 0.0
    private var last: Date?
    private var voice = 0.0
    private var lastState: JarvisVisualState?
    private var ripples: [Double] = []

    func advance(to date: Date, state: JarvisVisualState, level: Float) {
        let dt = min(0.1, max(0, last.map { date.timeIntervalSince($0) } ?? 0))
        last = date
        let speed = state.appearance.speed
        let degreesPerSecond = { (rpm: Double) in rpm * 6 * speed }

        for i in angles.indices { angles[i] += degreesPerSecond(Self.rings[i].rpm) * dt }
        sweep += degreesPerSecond(3.2) * dt
        reticle += degreesPerSecond(-0.45) * dt
        iris += degreesPerSecond(11) * dt
        phase += dt * speed

        // The disc swells with the voice while listening or speaking; otherwise the breathing owns its scale.
        let target = (state == .listening || state == .speaking) ? Double(min(max(level, 0), 1)) : 0
        voice += (target - voice) * min(1, dt * 18)

        // Every change of state is announced once by a ring leaving the disc. Not on the first paint.
        if let lastState, lastState != state { ripples.append(0) }
        lastState = state
        ripples = ripples.map { $0 + dt / 0.85 }.filter { $0 < 1 }
    }

    func draw(in context: inout GraphicsContext, size: CGSize, state: JarvisVisualState) {
        let side = min(size.width, size.height)
        let scale = side / 400
        context.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
        context.scaleBy(x: scale, y: scale)

        let (accentRGB, _, brightness) = state.appearance
        let accent = accentRGB.color
        let highlight = state.highlight.color
        let centre = CGPoint(x: 200, y: 200)
        func shade(_ fraction: Double) -> Double { min(1, fraction * brightness) }
        let weights = [shade(0.34), shade(0.66), shade(1.0)]

        // Backdrop glow.
        context.fill(Path(ellipseIn: CGRect(x: 8, y: 8, width: 384, height: 384)),
                     with: .radialGradient(Gradient(colors: [Color(red: 0, green: 130 / 255, blue: 170 / 255).opacity(38 / 255), .clear]),
                                           center: centre, startRadius: 0, endRadius: 192))

        for (i, ring) in Self.rings.enumerated() {
            var layer = context
            layer.translateBy(x: 200, y: 200)
            layer.rotate(by: .degrees(angles[i]))
            layer.translateBy(x: -200, y: -200)

            var opacity = ring.accent ? shade(1.0) : weights[min(max(ring.weight, 0), 2)]
            if ring.pulse {
                // 0.35 to 1 and back, 2.2 s each way at normal tempo; phase already runs at the state's speed.
                opacity *= 0.35 + 0.65 * (0.5 - 0.5 * cos(phase * .pi / 2.2))
            }
            let colour = (ring.accent ? highlight : accent).opacity(opacity)
            let stroke = StrokeStyle(lineWidth: ring.thickness, lineCap: .round, dash: ring.style == .dashed ? [3, 6] : [])

            switch ring.style {
            case .dots:
                var dots = Path()
                for k in 0..<54 {
                    let p = Self.point(ring.radius, Double(k) * 360 / 54)
                    let r = ring.thickness / 2
                    dots.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                }
                layer.fill(dots, with: .color(colour))
            case .ticks:
                var ticks = Path()
                for k in 0..<ring.count {
                    let angle = Double(k) * 360 / Double(ring.count)
                    let length = k % 6 == 0 ? 12.0 : 6.0
                    ticks.move(to: Self.point(ring.radius - length, angle))
                    ticks.addLine(to: Self.point(ring.radius, angle))
                }
                layer.stroke(ticks, with: .color(colour), style: stroke)
            case .blocks:
                let blocks = Self.arcs(ring.radius, (0..<ring.count).map { (Double($0) * 360 / Double(ring.count), 7.0) })
                layer.stroke(blocks, with: .color(colour), style: stroke)
            case .arcs:
                if ring.accent {
                    var glow = layer
                    glow.addFilter(.blur(radius: 6))
                    glow.stroke(Self.arcs(ring.radius, ring.segments), with: .color(highlight.opacity(0.7 * opacity)), style: stroke)
                }
                layer.stroke(Self.arcs(ring.radius, ring.segments), with: .color(colour), style: stroke)
            case .dashed:
                layer.stroke(Path(ellipseIn: CGRect(x: 200 - ring.radius, y: 200 - ring.radius, width: ring.radius * 2, height: ring.radius * 2)),
                             with: .color(colour), style: stroke)
            }
        }

        // The sweep: a wedge fading behind its leading edge, so rotation reads as a scan.
        do {
            var layer = context
            layer.translateBy(x: 200, y: 200)
            layer.rotate(by: .degrees(sweep))
            var wedge = Path()
            wedge.addArc(center: .zero, radius: 155, startAngle: .degrees(0), endAngle: .degrees(34), clockwise: false)
            wedge.addArc(center: .zero, radius: 118, startAngle: .degrees(34), endAngle: .degrees(0), clockwise: true)
            wedge.closeSubpath()
            layer.fill(wedge, with: .linearGradient(Gradient(colors: [accent.opacity(shade(0.30)), accent.opacity(0)]),
                                                     startPoint: CGPoint(x: 150, y: 40), endPoint: CGPoint(x: 120, y: -40)))
        }

        // The reticle: four bracket marks turning slowly the other way.
        do {
            var layer = context
            layer.translateBy(x: 200, y: 200)
            layer.rotate(by: .degrees(reticle))
            layer.translateBy(x: -200, y: -200)
            var marks = Path()
            for corner in [45.0, 135.0, 225.0, 315.0] {
                let apex = Self.point(199, corner)
                let r = corner * .pi / 180
                let tangent = CGVector(dx: -sin(r), dy: cos(r))
                let inward = CGVector(dx: -cos(r), dy: -sin(r))
                marks.move(to: apex); marks.addLine(to: CGPoint(x: apex.x + tangent.dx * 14, y: apex.y + tangent.dy * 14))
                marks.move(to: apex); marks.addLine(to: CGPoint(x: apex.x - tangent.dx * 14, y: apex.y - tangent.dy * 14))
                marks.move(to: apex); marks.addLine(to: CGPoint(x: apex.x + inward.dx * 7.7, y: apex.y + inward.dy * 7.7))
            }
            layer.stroke(marks, with: .color(accent.opacity(shade(0.85))), style: StrokeStyle(lineWidth: 1.2, lineCap: .square))
        }

        // The iris: three arcs hugging the disc, fastest while thinking.
        do {
            var layer = context
            layer.translateBy(x: 200, y: 200)
            layer.rotate(by: .degrees(iris))
            layer.translateBy(x: -200, y: -200)
            layer.stroke(Self.arcs(72, [(0, 70), (120, 70), (240, 70)]), with: .color(accent.opacity(shade(0.9))),
                         style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }

        // Data blocks: each lights on its own fixed phase and period, a readout rather than a fairground.
        for i in 0..<16 {
            let angle = 2 * Double.pi * Double(i) / 16
            let period = 1.3 + 0.37 * Double((i * 7) % 5)
            let offset = period * Double((i * 11) % 16) / 16
            let wave = 0.5 - 0.5 * cos((phase + offset) * .pi / period)
            var block = context
            block.translateBy(x: 200 + 93 * cos(angle), y: 200 + 93 * sin(angle))
            block.rotate(by: .radians(angle + .pi / 2))
            block.fill(Path(CGRect(x: -2.5, y: -1.2, width: 5, height: 2.4)), with: .color(accent.opacity(shade(0.9) * (0.12 + 0.88 * wave))))
        }

        // The centre: glow, rim and the hot disc, breathing and swelling with the voice.
        // 0.9 to 1.1 over 2.6 s each way, and the glow 0.55 to 1 over 1.9 s, as the PC's Breathe and glow animations.
        let breathe = 1.0 + 0.1 * sin(phase * .pi / 2.6)
        let glowAlpha = 0.55 + 0.45 * (0.5 + 0.5 * sin(phase * .pi / 1.9))
        let glowR = 85 * breathe
        context.fill(Path(ellipseIn: CGRect(x: 200 - glowR, y: 200 - glowR, width: glowR * 2, height: glowR * 2)),
                     with: .radialGradient(Gradient(colors: [accent.opacity(shade(0.47) * glowAlpha), .clear]), center: centre, startRadius: 0, endRadius: glowR))

        let rimR = 59 * (1 + voice * 0.18)
        context.stroke(Path(ellipseIn: CGRect(x: 200 - rimR, y: 200 - rimR, width: rimR * 2, height: rimR * 2)), with: .color(accent.opacity(shade(0.53))), lineWidth: 1)

        let discR = 52 * (1 + voice * 0.35)
        let disc = Path(ellipseIn: CGRect(x: 200 - discR, y: 200 - discR, width: discR * 2, height: discR * 2))
        var shine = context
        shine.addFilter(.blur(radius: 14))
        shine.fill(disc, with: .color(accent.opacity(0.9)))
        context.fill(disc, with: .radialGradient(Gradient(colors: [Color(red: 0xD8 / 255, green: 0xFB / 255, blue: 0xFC / 255).opacity(shade(0.95)), accent.opacity(shade(0.20))]),
                                                  center: centre, startRadius: 0, endRadius: discR))
        context.stroke(disc, with: .color(accent), lineWidth: 2)

        for progress in ripples {
            let eased = 1 - pow(1 - progress, 3)
            let r = 60 * (1 + 1.9 * eased)
            context.stroke(Path(ellipseIn: CGRect(x: 200 - r, y: 200 - r, width: r * 2, height: r * 2)),
                           with: .color(accent.opacity(0.7 * (1 - eased) * 0.63)), lineWidth: 1.5)
        }
    }

    private static func point(_ radius: Double, _ degrees: Double) -> CGPoint {
        let r = degrees * .pi / 180
        return CGPoint(x: 200 + radius * cos(r), y: 200 + radius * sin(r))
    }

    private static func arcs(_ radius: Double, _ segments: [(Double, Double)]) -> Path {
        var path = Path()
        for (start, sweep) in segments {
            path.move(to: point(radius, start))
            path.addArc(center: CGPoint(x: 200, y: 200), radius: radius, startAngle: .degrees(start), endAngle: .degrees(start + sweep), clockwise: false)
        }
        return path
    }
}
