import Foundation
import simd

/// What the face is doing: the visual states reduced to what changes a gaze. The PC's `FaceMood`.
enum FaceMood {
    case neutral, listening, thinking, speaking, asleep
    /// Security Protocol: controlled, stern, minimal, direct.
    case security
}

/// One frame of the mouth's schedule: loudness, openness and width for 20 ms of audio. The PC's `MouthFrame`.
struct MouthFrame {
    var level: Float
    var openness: Float
    var width: Float
}

/// Everything the renderer needs about the face this frame, other than the geometry.
struct FacePose {
    var mouth: Float = 0, wide: Float = 0, brow: Float = 0
    var yaw: Float = 0, pitch: Float = 0
    var gazeX: Float = 0, gazeY: Float = 0
    var lids: Float = 1, blink: Float = 0, glow: Float = 0, scan: Float = -1.6
}

/// The face's animation - a line-for-line port of the PC's `FaceAnimator` (Mark LIV's `HoloAvatar.step`), so the
/// head on the phone moves exactly as the head on the glass does.
final class FaceAnimator {
    static let hopSeconds: Float = 0.02

    private let tauOpen: Float = 0.022
    private let tauShut: Float = 0.012
    private let tauRest: Float = 0.055
    private let tauShape: Float = 0.018
    private let micFloor: Float = 0.14
    private let closeFraction: Float = 0.10

    let mesh: HeadMesh
    private var posed: [SIMD3<Float>]
    private var posedNormals: [SIMD3<Float>]

    private var t: Float = 0
    private var sway: Float = 0
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var mouth: Float = 0
    private var glow: Float = 0
    private var scan: Float = -1.6
    private var blink: Float = 0
    private var blinkAt: Float = 3

    private var ampSlow: Float = 0
    private var expr: Float = 0
    private var exprTarget: Float = 0
    private var exprAt: Float = 0
    private var brow: Float = 0
    private var emph: Float = 0
    private var gaze: [Float] = [0, 0]
    private var gazeTarget: [Float] = [0, 0]
    private var gazeAt: Float = 0

    private var gazeBias: [Float] = [0, 0]
    private var biasTarget: [Float] = [0, 0]
    private var biasAt: Float = 0
    private var lids: Float = 1
    private var browBias: Float = 0

    private var visemeOpen: Float = 1
    private var wide: Float = 0
    private var voicePeak: Float = 0.18

    init(mesh: HeadMesh) {
        self.mesh = mesh
        posed = mesh.vertices
        posedNormals = mesh.normals
    }

    var pose: FacePose {
        FacePose(mouth: mouth, wide: wide, brow: brow, yaw: yaw, pitch: pitch, gazeX: gaze[0], gazeY: gaze[1],
                 lids: lids, blink: blink, glow: glow, scan: scan)
    }

    /// Per-frame lerp factor for an exponential approach with time constant tau. Frame-rate independent.
    static func rate(_ dt: Float, _ tau: Float) -> Float { 1 - exp(-dt / tau) }

    private func clamp(_ value: Float, _ low: Float, _ high: Float) -> Float { min(max(value, low), high) }

    private func uniform(_ low: Float, _ high: Float) -> Float { Float.random(in: low...high) }

    private func mouthStep(_ dt: Float, _ amp: Float, _ live: Bool, _ visemeOpenTarget: Float?, _ visemeLevel: Float?) {
        var shape: Float = 1
        if let target = visemeOpenTarget {
            visemeOpen += (target - visemeOpen) * Self.rate(dt, tauShape)
            shape = visemeOpen
        }

        var drive: Float
        if let level = visemeLevel {
            voicePeak = max(level, voicePeak - dt * 0.55)
            let reference = max(0.18, voicePeak)
            let q = (level - closeFraction * reference) / (reference * (1 - closeFraction))
            drive = pow(clamp(q, 0, 1), 0.85) * pow(shape, 0.75)
        } else {
            let gated = max(0, (amp - micFloor) / (1 - micFloor))
            drive = pow(gated, 0.6) * pow(shape, 0.75)
        }

        let target = live ? min(1, drive) : 0
        let tau = target > mouth ? tauOpen : live ? tauShut : tauRest
        mouth += (target - mouth) * Self.rate(dt, tau)
        if mouth < 0.002 { mouth = 0 }
    }

    /// Advance the animation. `schedule` is every mouth frame heard since the last step: nil means none is playing
    /// (loudness only), empty means one is playing but no new frame was heard, so the mouth is not stepped twice.
    func step(dt rawDt: Float, amp rawAmp: Float, mood: FaceMood, muted: Bool = false, schedule: [MouthFrame]? = nil) {
        let dt = clamp(rawDt, 0.001, 0.10)
        t += dt
        let amp = clamp(rawAmp, 0, 1)
        let live = mood == .speaking && !muted

        let security = mood == .security
        let speed: Float = (muted ? 0.55 : 1) * (live ? 1.25 : 1) * (security ? 0.35 : 1)
        sway += dt * speed
        let s = sway
        yaw = 0.26 * sin(s * 0.31) + 0.09 * sin(s * 0.73 + 1.3)
        pitch = 0.060 * sin(s * 0.23 + 0.7) + 0.024 * sin(s * 0.61)

        var wideTarget: Float?
        if let schedule {
            for frame in schedule {
                mouthStep(Self.hopSeconds, amp, live, frame.openness, frame.level)
                wideTarget = frame.width
            }
        } else {
            mouthStep(dt, amp, live, nil, nil)
        }

        emph += (mouth - emph) * Self.rate(dt, mouth > emph ? 0.055 : 0.32)
        pitch -= emph * 0.028
        yaw += 0.018 * sin(t * 1.7) * emph

        let envelope = live ? amp : 0
        ampSlow += (envelope - ampSlow) * Self.rate(dt, envelope > ampSlow ? 0.16 : 0.36)

        if live {
            if t >= exprAt {
                exprTarget = uniform(-0.35, 1.0)
                exprAt = t + 1.1 + 2.0 * Float.random(in: 0..<1)
            }
        } else {
            exprTarget = 0
            exprAt = t + 0.8
        }
        expr += (exprTarget - expr) * 0.075

        let browTarget = 0.55 * ampSlow + 0.60 * expr + browBias
        brow += (clamp(browTarget, -0.4, 1.2) - brow) * 0.20

        let thinking = mood == .thinking
        let asleep = mood == .asleep
        var nextBrowBias: Float
        var lidTarget: Float

        if thinking {
            if t >= biasAt {
                biasTarget[0] = (Bool.random() ? -1 : 1) * uniform(0.45, 0.8)
                biasTarget[1] = uniform(0.25, 0.55)
                biasAt = t + 1.4 + 1.6 * Float.random(in: 0..<1)
            }
            nextBrowBias = -0.28
            lidTarget = 0.94
        } else if asleep {
            biasTarget = [0, -0.25]
            nextBrowBias = -0.05
            lidTarget = 0.22
        } else if security {
            biasTarget = [0, 0]
            biasAt = 0
            nextBrowBias = -0.22
            lidTarget = 0.92
        } else {
            biasTarget = [0, 0]
            biasAt = 0
            nextBrowBias = mood == .listening ? 0.10 : 0
            lidTarget = 1
        }

        for i in 0..<2 { gazeBias[i] += (biasTarget[i] - gazeBias[i]) * 0.06 }
        lids += (lidTarget - lids) * 0.08
        browBias += (nextBrowBias - browBias) * 0.06

        if t >= gazeAt {
            let reach: Float = security ? 0.08 : live ? 0.9 : thinking ? 0.35 : 0.55
            gazeTarget[0] = uniform(-1, 1) * reach
            gazeTarget[1] = uniform(-1, 1) * reach * 0.55
            gazeAt = live ? t + 0.55 + 1.7 * Float.random(in: 0..<1)
                : thinking ? t + 1.8 + 2.4 * Float.random(in: 0..<1)
                : t + 1.3 + 2.8 * Float.random(in: 0..<1)
        }

        for i in 0..<2 {
            let target = clamp(gazeTarget[i] + gazeBias[i], -1, 1)
            gaze[i] += (target - gaze[i]) * 0.30
        }

        let wideGoal: Float = live ? (wideTarget ?? 0) : 0
        wide += (clamp(wideGoal, -1, 1) - wide) * Self.rate(dt, 0.030)

        let glowTarget: Float = muted ? 0 : amp
        glow += (glowTarget - glow) * (glowTarget > glow ? 0.35 : 0.10)

        scan += dt * (0.55 + 1.5 * glow)
        if scan > 1.35 { scan = -1.75 }

        if blink > 0 {
            blink = max(0, blink - dt * 8.5)
        } else if t >= blinkAt {
            if asleep {
                blinkAt = t + 6
            } else {
                blink = 1
                let gap: Float = thinking ? 5.5 : security ? 7.0 : 3.4
                blinkAt = t + gap + 3.1 * Float.random(in: 0..<1)
            }
        }
    }

    /// Jaw drop, lip spread, brow lift and head rotation applied to the real geometry.
    func poseGeometry() -> (vertices: [SIMD3<Float>], normals: [SIMD3<Float>]) {
        let v0 = mesh.vertices
        let n0 = mesh.normals
        let count = v0.count

        posed.withUnsafeMutableBufferPointer { v in
            for i in 0..<count { v[i] = v0[i] }

            if abs(brow) > 0.004 {
                let lift = brow * mesh.browLift
                for i in 0..<count { v[i].y += mesh.brow[i] * lift }
            }

            if abs(wide) > 0.01 && mouth > 0 {
                let centre = mesh.lipCentre
                for i in 0..<count {
                    let k = mesh.lips[i] * (wide * mouth)
                    if k == 0 { continue }
                    v[i].x += k * (v[i].x - centre.x) * 0.55
                    v[i].y += k * (v[i].y - centre.y) * 0.30
                    v[i].z -= k * 0.055
                }
            }

            if mouth > 0.004 {
                let pivot = mesh.jawPivot
                for i in 0..<count {
                    let angle = mesh.jaw[i] * (mouth * mesh.jawMax)
                    if angle == 0 { continue }
                    let ca = cos(angle), sa = sin(angle)
                    let dy = v[i].y - pivot.y, dz = v[i].z - pivot.z
                    v[i].y = pivot.y + dy * ca - dz * sa
                    v[i].z = pivot.z + dy * sa + dz * ca
                }
            }

            let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)
            let r0 = SIMD3<Float>(cy, 0, sy)
            let r1 = SIMD3<Float>(sp * sy, cp, -sp * cy)
            let r2 = SIMD3<Float>(-cp * sy, sp, cp * cy)

            posedNormals.withUnsafeMutableBufferPointer { n in
                for i in 0..<count {
                    let p = v[i]
                    v[i] = SIMD3(simd_dot(r0, p), simd_dot(r1, p), simd_dot(r2, p))
                    let m = n0[i]
                    n[i] = SIMD3(simd_dot(r0, m), simd_dot(r1, m), simd_dot(r2, m))
                }
            }
        }

        return (posed, posedNormals)
    }
}
