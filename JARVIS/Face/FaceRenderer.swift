import CoreGraphics
import Foundation
import simd

/// The PC's `JarvisFace` painting, ported: a lit, wire-overlaid head drawn by a small software rasteriser into a
/// pixel buffer, then handed to SwiftUI as one image. Same projection, lighting, wire, eyes, brows, mouth and teeth.
///
/// Pixels are premultiplied BGRA in a `UInt32` each (`0xAARRGGBB` little-endian), which is exactly the PC's layout.
final class FaceRenderer {
    typealias RGB = JarvisVisualState.RGB

    private let cameraDistance: Float = 4.6
    private let headFraction: Float = 0.31
    private let ground = RGB(0x02, 0x06, 0x0B)
    private let amber = RGB(0xD9, 0xA2, 0x57)

    let size: Int
    private let mesh: HeadMesh
    private let pixels: UnsafeMutablePointer<UInt32>
    private var auraBase: [Float]
    private var auraGain: [Float]
    private var xs: [Float]
    private var ys: [Float]
    private var va: [Float]
    private var order: [(index: Int, depth: Float)] = []
    private let lipUp: [Int]

    init(mesh: HeadMesh, size: Int) {
        self.mesh = mesh
        self.size = max(48, size)
        let count = self.size * self.size
        pixels = UnsafeMutablePointer<UInt32>.allocate(capacity: count)
        pixels.initialize(repeating: 0, count: count)
        auraBase = [Float](repeating: 0, count: count)
        auraGain = [Float](repeating: 0, count: count)
        xs = [Float](repeating: 0, count: mesh.vertices.count)
        ys = xs
        va = xs
        order.reserveCapacity(mesh.faces.count)

        // The upper lip, for the teeth: the second half of the inner ring plus its start.
        let inner = mesh.ring("lips_in")
        lipUp = inner.count > 10 ? Array(inner[10...]) + [inner[0]] : inner

        // A fixed radial aura whose brightness moves with the voice: two coefficients per pixel, computed once.
        let centre = Float(self.size - 1) / 2
        let radius = Float(self.size) * headFraction * 1.95
        for py in 0..<self.size {
            for px in 0..<self.size {
                let dx = Float(px) - centre, dy = Float(py) - centre
                let d = (dx * dx + dy * dy).squareRoot() / radius
                if d >= 1 { continue }
                let i = py * self.size + px
                if d < 0.38 {
                    let t = d / 0.38
                    auraBase[i] = (34 + (20 - 34) * t) / 255
                    auraGain[i] = (66 + (40 - 66) * t) / 255
                } else {
                    let t = (d - 0.38) / 0.62
                    auraBase[i] = 20 * (1 - t) / 255
                    auraGain[i] = 40 * (1 - t) / 255
                }
            }
        }
    }

    deinit { pixels.deallocate() }

    // MARK: frame

    func paint(pose: FacePose, vertices verts: [SIMD3<Float>], normals norms: [SIMD3<Float>], primary: RGB) -> CGImage? {
        let count = size * size
        pixels.update(repeating: 0, count: count)
        let amp = pose.glow

        for i in 0..<count {
            let a = auraBase[i] + auraGain[i] * amp
            if a > 0.002 { blend(i, primary, a) }
        }

        let centre = Float(size - 1) / 2
        let r = Float(size) * headFraction
        for i in 0..<verts.count {
            let w = max(0.35, cameraDistance - verts[i].z)
            let k = cameraDistance / w * r
            xs[i] = centre + verts[i].x * k
            ys[i] = centre - verts[i].y * k
        }

        paintSurface(verts, norms, primary, amp)
        paintWire(verts, norms, primary, amp, pose.scan)
        paintFeatures(pose, primary, amp)
        return image()
    }

    private func image() -> CGImage? {
        let bytes = size * size * 4
        guard let provider = CGDataProvider(data: Data(bytes: pixels, count: bytes) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: layers

    private func paintSurface(_ verts: [SIMD3<Float>], _ norms: [SIMD3<Float>], _ primary: RGB, _ amp: Float) {
        order.removeAll(keepingCapacity: true)

        for (f, face) in mesh.faces.enumerated() {
            let (a, b, c) = face
            let area = abs((xs[b] - xs[a]) * (ys[c] - ys[a]) - (xs[c] - xs[a]) * (ys[b] - ys[a]))
            if area <= 3 { continue }

            var n = simd_cross(verts[b] - verts[a], verts[c] - verts[a])
            let len = simd_length(n)
            if len < 1e-9 { continue }
            n /= len
            if simd_dot(n, norms[a] + norms[b] + norms[c]) < 0 { n = -n }
            if n.z <= 0.015 { continue }

            // Neck facets draw before every head facet, so the two meshes never interleave into a torn seam.
            let depth = (verts[a].z + verts[b].z + verts[c].z) / 3 + Float(mesh.faceGroup[f]) * 1000
            order.append((f, depth))
        }

        order.sort { $0.depth < $1.depth }

        for entry in order {
            let (a, b, c) = mesh.faces[entry.index]
            var n = simd_normalize(simd_cross(verts[b] - verts[a], verts[c] - verts[a]))
            if simd_dot(n, norms[a] + norms[b] + norms[c]) < 0 { n = -n }

            // A rim term for the glass edge and a key light high on the left.
            let fres = pow(min(max(1 - n.z, 0), 2), 1.7)
            let lam = min(max(n.x * -0.55 + n.y * 0.50 + n.z * 0.52, 0), 1)
            var bright = 0.26 + 0.20 * fres + 0.66 * pow(lam, 1.05)
            bright *= (mesh.fade[a] + mesh.fade[b] + mesh.fade[c]) / 3
            bright *= 0.88 + 0.24 * amp

            fillTriangle(xs[a], ys[a], xs[b], ys[b], xs[c], ys[c], ground.mix(primary, min(max(bright, 0), 1)))
        }
    }

    private func paintWire(_ verts: [SIMD3<Float>], _ norms: [SIMD3<Float>], _ primary: RGB, _ amp: Float, _ scan: Float) {
        for i in 0..<verts.count {
            let nz = norms[i].z
            if nz <= -0.05 { va[i] = 0; continue }
            let fres = pow(abs(1 - abs(nz)), 1.5)
            let band = (verts[i].y - scan) / 0.13
            let value = 0.10 + 0.42 * fres + 0.30 * exp(-band * band)
            va[i] = value * mesh.fade[i] * (0.80 + 0.45 * amp)
        }

        let skin = ground.mix(primary, 132 / 255)
        for (a, b) in mesh.edges {
            let alpha = 0.5 * (va[a] + va[b])
            if alpha <= 0.05 { continue }
            drawLine(xs[a], ys[a], xs[b], ys[b], skin.mix(primary, min(1, alpha) * 0.75), min(1, alpha * 1.6))
        }
    }

    private func paintFeatures(_ pose: FacePose, _ primary: RGB, _ amp: Float) {
        let facing = pow(max(0, cos(pose.yaw) * cos(pose.pitch)), 2)
        if facing < 0.02 { return }
        let open = 1 - pose.blink

        for key in ["eye_l", "eye_r"] {
            let idx = mesh.ring(key)
            if idx.isEmpty { continue }
            let midY = idx.reduce(Float(0)) { $0 + ys[$1] } / Float(idx.count)
            let pts: [(Float, Float)] = idx.map { i in
                var y = ys[i]
                if open < 0.999 { y = midY + (y - midY) * max(0.04, open) }
                return (xs[i], y)
            }

            fillPolygon(pts, ground.mix(primary, 22 / 255), 1)
            strokePolygon(pts, primary, 210 / 255 * facing, closed: true)

            if open > 0.35 {
                let (minX, maxX, minY, maxY) = bounds(pts)
                let w = maxX - minX, h = maxY - minY
                let gx = (minX + maxX) / 2 + pose.gazeX * w * 0.16
                let gy = (minY + maxY) / 2 + pose.gazeY * h * 0.20
                let rad = min(h * 0.62, w * 0.20)
                fillEllipse(gx, gy, rad, rad * open, amber, (70 + 60 * amp) / 255 * facing * open)
                fillEllipse(gx, gy, rad * 0.42, rad * 0.42 * open, amber, 245 / 255 * facing * open)
            }
        }

        for key in ["brow_l", "brow_r"] {
            strokePolygon(ring(mesh.ring(key)), primary, 150 / 255 * facing, closed: false, width: 1.7)
        }

        let inner = ring(mesh.ring("lips_in"))
        let (_, _, innerTop, innerBottom) = bounds(inner)
        let openHeight = innerBottom - innerTop

        if pose.mouth > 0.02 {
            // Dark but never black: a black oval on a glowing head reads as a hole, not a mouth.
            fillPolygon(inner, ground.mix(primary, (16 + 26 * pose.mouth) / 255), 1)

            let th = openHeight * 0.30
            var teeth: [(Float, Float)] = lipUp.map { (xs[$0], ys[$0]) }
            for j in lipUp.reversed() { teeth.append((xs[j], ys[j] + th)) }
            fillPolygon(teeth, ground.mix(primary, (150 + 60 * pose.mouth) / 255), 1)

            fillPolygon(inner, amber, 40 / 255 * pose.mouth * facing)
        }

        strokePolygon(inner, primary, (150 + 70 * pose.mouth) / 255 * facing, closed: true)
        strokePolygon(ring(mesh.ring("lips_out")), primary, 110 / 255 * facing, closed: true)
    }

    private func ring(_ idx: [Int]) -> [(Float, Float)] { idx.map { (xs[$0], ys[$0]) } }

    private func bounds(_ pts: [(Float, Float)]) -> (Float, Float, Float, Float) {
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        for (x, y) in pts {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        return (minX, maxX, minY, maxY)
    }

    // MARK: rasteriser

    private func blend(_ index: Int, _ colour: RGB, _ alpha: Float) {
        if alpha <= 0 { return }
        if alpha >= 1 {
            pixels[index] = 0xFF00_0000 | (UInt32(colour.r) << 16) | (UInt32(colour.g) << 8) | UInt32(colour.b)
            return
        }
        let d = pixels[index]
        let inv = 1 - alpha
        let a = UInt32(min(255, alpha * 255 + Float(d >> 24) * inv))
        let r = UInt32(min(255, colour.r * alpha + Float((d >> 16) & 0xFF) * inv))
        let g = UInt32(min(255, colour.g * alpha + Float((d >> 8) & 0xFF) * inv))
        let b = UInt32(min(255, colour.b * alpha + Float(d & 0xFF) * inv))
        pixels[index] = (a << 24) | (r << 16) | (g << 8) | b
    }

    private func plot(_ x: Int, _ y: Int, _ colour: RGB, _ alpha: Float) {
        if x < 0 || y < 0 || x >= size || y >= size { return }
        blend(y * size + x, colour, alpha)
    }

    /// Opaque, aliased fill: adjacent antialiased triangles leave hairline seams, and the wire covers the outline.
    private func fillTriangle(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float, _ colour: RGB) {
        let minY = max(0, Int(floor(min(y0, min(y1, y2)))))
        let maxY = min(size - 1, Int(ceil(max(y0, max(y1, y2)))))
        let minX = max(0, Int(floor(min(x0, min(x1, x2)))))
        let maxX = min(size - 1, Int(ceil(max(x0, max(x1, x2)))))
        if minY > maxY || minX > maxX { return }

        let area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
        if abs(area) < 1e-6 { return }
        let sign: Float = area > 0 ? 1 : -1
        let packed: UInt32 = 0xFF00_0000 | (UInt32(colour.r) << 16) | (UInt32(colour.g) << 8) | UInt32(colour.b)

        for y in minY...maxY {
            let py = Float(y) + 0.5
            let row = y * size
            for x in minX...maxX {
                let px = Float(x) + 0.5
                let w0 = ((x1 - px) * (y2 - py) - (x2 - px) * (y1 - py)) * sign
                let w1 = ((x2 - px) * (y0 - py) - (x0 - px) * (y2 - py)) * sign
                let w2 = ((x0 - px) * (y1 - py) - (x1 - px) * (y0 - py)) * sign
                if w0 >= 0 && w1 >= 0 && w2 >= 0 { pixels[row + x] = packed }
            }
        }
    }

    /// Even-odd scanline fill of a closed ring.
    private func fillPolygon(_ pts: [(Float, Float)], _ colour: RGB, _ alpha: Float) {
        if pts.count < 3 || alpha <= 0 { return }
        let (_, _, minYf, maxYf) = bounds(pts)
        let minY = max(0, Int(floor(minYf)))
        let maxY = min(size - 1, Int(ceil(maxYf)))
        if minY > maxY { return }
        var crossings: [Float] = []
        crossings.reserveCapacity(pts.count)

        for y in minY...maxY {
            let py = Float(y) + 0.5
            crossings.removeAll(keepingCapacity: true)
            for i in 0..<pts.count {
                let (ax, ay) = pts[i]
                let (bx, by) = pts[(i + 1) % pts.count]
                if ay == by { continue }
                if (py >= ay && py < by) || (py >= by && py < ay) {
                    crossings.append(ax + (py - ay) / (by - ay) * (bx - ax))
                }
            }
            crossings.sort()
            var i = 0
            while i + 1 < crossings.count {
                let x0 = max(0, Int(crossings[i].rounded()))
                let x1 = min(size - 1, Int(crossings[i + 1].rounded()) - 1)
                if x0 <= x1 { for x in x0...x1 { blend(y * size + x, colour, alpha) } }
                i += 2
            }
        }
    }

    private func fillEllipse(_ cx: Float, _ cy: Float, _ rx: Float, _ ry: Float, _ colour: RGB, _ alpha: Float) {
        if rx <= 0 || ry <= 0 || alpha <= 0 { return }
        let minY = max(0, Int(floor(cy - ry))), maxY = min(size - 1, Int(ceil(cy + ry)))
        let minX = max(0, Int(floor(cx - rx))), maxX = min(size - 1, Int(ceil(cx + rx)))
        if minY > maxY || minX > maxX { return }
        for y in minY...maxY {
            let dy = (Float(y) + 0.5 - cy) / ry
            for x in minX...maxX {
                let dx = (Float(x) + 0.5 - cx) / rx
                let d = dx * dx + dy * dy
                if d > 1 { continue }
                let edge = min(max((1 - d.squareRoot()) * min(rx, ry), 0), 1)
                blend(y * size + x, colour, alpha * edge)
            }
        }
    }

    private func strokePolygon(_ pts: [(Float, Float)], _ colour: RGB, _ alpha: Float, closed: Bool, width: Float = 1.3) {
        if pts.count < 2 || alpha <= 0 { return }
        let count = closed ? pts.count : pts.count - 1
        for i in 0..<count {
            let (ax, ay) = pts[i]
            let (bx, by) = pts[(i + 1) % pts.count]
            drawLine(ax, ay, bx, by, colour, alpha)
            if width > 1.2 { drawLine(ax, ay + 0.6, bx, by + 0.6, colour, alpha * (width - 1)) }
        }
    }

    /// Wu's antialiased line, blended.
    private func drawLine(_ ax0: Float, _ ay0: Float, _ ax1: Float, _ ay1: Float, _ colour: RGB, _ alpha: Float) {
        var x0 = ax0, y0 = ay0, x1 = ax1, y1 = ay1
        let steep = abs(y1 - y0) > abs(x1 - x0)
        if steep { swap(&x0, &y0); swap(&x1, &y1) }
        if x0 > x1 { swap(&x0, &x1); swap(&y0, &y1) }

        let dx = x1 - x0
        let gradient = dx < 1e-6 ? 1 : (y1 - y0) / dx
        let xEnd = x0.rounded()
        var interY = y0 + gradient * (xEnd - x0)
        let xPixel1 = Int(xEnd)
        let xPixel2 = Int(x1.rounded())
        if xPixel1 > xPixel2 { return }

        for x in xPixel1...xPixel2 {
            let yi = Int(floor(interY))
            let frac = interY - Float(yi)
            if steep {
                plot(yi, x, colour, alpha * (1 - frac))
                plot(yi + 1, x, colour, alpha * frac)
            } else {
                plot(x, yi, colour, alpha * (1 - frac))
                plot(x, yi + 1, colour, alpha * frac)
            }
            interY += gradient
        }
    }
}
