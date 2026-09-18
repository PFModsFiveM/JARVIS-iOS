import Foundation
import simd

/// The head the face is drawn on - the PC's `HeadMesh.Build()`, exported by `SpeechDiag head-mesh` into
/// `Resources/head-mesh.json`, so the phone draws exactly the same geometry and rigs as the HUD.
///
/// Coordinates are head-local and normalised: +x to the viewer's right, +y up, +z out of the face; y = +1 at the crown,
/// -1 at the chin. MediaPipe canonical face model (Apache-2.0).
final class HeadMesh {
    let vertices: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    /// Triangles, three vertex indices each.
    let faces: [(Int, Int, Int)]
    /// Wireframe edges.
    let edges: [(Int, Int)]
    let jaw: [Float]
    let brow: [Float]
    let lips: [Float]
    let fade: [Float]
    /// 1 for the head, 0 for the neck; the neck always draws first.
    let faceGroup: [Int]
    let lipCentre: SIMD3<Float>
    let jawPivot: SIMD3<Float>
    let jawMax: Float
    let browLift: Float
    let landmarks: [String: [Int]]

    /// The one head every face shares; nil only if the bundled file is missing or damaged.
    static let shared: HeadMesh? = HeadMesh.load()

    private init(json: [String: Any]) throws {
        func floats(_ key: String) throws -> [Float] {
            guard let values = json[key] as? [NSNumber] else { throw CocoaError(.fileReadCorruptFile) }
            return values.map { $0.floatValue }
        }
        func ints(_ key: String) throws -> [Int] {
            guard let values = json[key] as? [NSNumber] else { throw CocoaError(.fileReadCorruptFile) }
            return values.map { $0.intValue }
        }
        func points(_ key: String) throws -> [SIMD3<Float>] {
            let flat = try floats(key)
            return stride(from: 0, to: flat.count - 2, by: 3).map { SIMD3(flat[$0], flat[$0 + 1], flat[$0 + 2]) }
        }

        vertices = try points("vertices")
        normals = try points("normals")
        let f = try ints("faces")
        faces = stride(from: 0, to: f.count - 2, by: 3).map { (f[$0], f[$0 + 1], f[$0 + 2]) }
        let e = try ints("edges")
        edges = stride(from: 0, to: e.count - 1, by: 2).map { (e[$0], e[$0 + 1]) }
        jaw = try floats("jaw")
        brow = try floats("brow")
        lips = try floats("lips")
        fade = try floats("fade")
        faceGroup = try ints("faceGroup")
        lipCentre = try points("lipCentre").first ?? .zero
        jawPivot = try points("jawPivot").first ?? .zero
        jawMax = (json["jawMax"] as? NSNumber)?.floatValue ?? 0.115
        browLift = (json["browLift"] as? NSNumber)?.floatValue ?? 0.14

        var rings: [String: [Int]] = [:]
        for (name, value) in (json["landmarks"] as? [String: Any]) ?? [:] {
            rings[name] = (value as? [NSNumber])?.map { $0.intValue } ?? []
        }
        landmarks = rings

        let n = vertices.count
        guard normals.count == n, jaw.count == n, brow.count == n, lips.count == n, fade.count == n,
              faceGroup.count == faces.count,
              faces.allSatisfy({ $0.0 < n && $0.1 < n && $0.2 < n }),
              edges.allSatisfy({ $0.0 < n && $0.1 < n }),
              ["eye_l", "eye_r", "brow_l", "brow_r", "lips_out", "lips_in"].allSatisfy({ name in
                  guard let ring = rings[name], !ring.isEmpty else { return false }
                  return ring.allSatisfy { index in index < n }
              })
        else { throw CocoaError(.fileReadCorruptFile) }
    }

    private static func load() -> HeadMesh? {
        guard let url = Bundle.main.url(forResource: "head-mesh", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return try? HeadMesh(json: json)
    }

    func ring(_ name: String) -> [Int] { landmarks[name] ?? [] }
}
