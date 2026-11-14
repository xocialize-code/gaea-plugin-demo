import CoreGraphics
import Foundation
import GaeaPluginKit
import GaeaProtocol
import ImageIO
import MLXToolKit
import UniformTypeIdentifiers
import simd

// `demo-part`: a stand-in for MES `mesh.generate_part` (a part made to fit a body: Gaea AB-T-0482, GPP-1 §3.3.4), so a
// host's part path can be checked without weights. It isn't a model. It reads the body's head bone and writes a small
// tuft above it: a skinned, tapered prism with a head joint, two chain joints and one spring. What it shows a host is
// everything a real part depends on: the body is read, the item is in the body's coordinates, and its skin and
// `VRMC_springBone` reach the client.

/// A read and a GLB write: well under 0.1 GB.
let partManifest = PackageManifest(
    license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
    provenance: Provenance(sourceRepo: "xocialize-code/gaea-plugin-demo", revision: "0.5.0", tier: 1),
    requirements: RequirementsManifest(
        footprints: [QuantFootprint(quant: .fp32, residentBytes: 0, peakActivationBytes: 100_000_000)],
        requiredBackends: [.metalGPU]),
    surfaces: [CharacterPartContract.descriptor(
        name: "demo_part",
        summary: "A tuft on the body's head bone, as wide as the box: a smoke test for a host's part path, not a hair model.",
        controls: CharacterPartControls(parts: [.hair], inputs: [.image], features: [.subjectBox, .bodyFit, .springBones, .colors],
                                        requiresSubjectBox: true))])

final class PartModel: PluginModel, @unchecked Sendable {
    func prepare(lane: LaneDefinition, context: WorkerContext) async throws {}
    func unload() async {}

    func run(_ job: Job, context: RunContext) async throws -> RunResult {
        guard job.operation == CharacterParts.operation else { throw GPPError(.unsupportedOperation, "demo-part only makes a part.") }
        // The kit's mapping, as a real plugin uses it: the box in pixels of the picture received, the body's bytes.
        let mapped = try CharacterParts.request(job)
        let request = mapped.request
        guard let box = request.subjectBox, let picture = request.image, let width = picture.width else {
            throw GPPError(.invalidRequest, "demo-part needs subject_box: where the head is in the picture.", detail: ["param": "subject_box"])
        }
        guard let body = request.body else {
            throw GPPError(.invalidRequest, "demo-part needs the body the part goes on.", detail: ["param": "body"])
        }
        let head = try DemoBody.head(body.data)
        // The tuft is as wide as the box is of the picture: 4 cm for a sliver, 12 cm for the whole width.
        let share = (box[2] - box[0]) / Float(width)
        let tuft = DemoTuft(head: head, halfWidth: 0.02 + 0.04 * share, springs: request.springBones ?? true,
                            color: (request.colors ?? true) ? DemoTuft.color(seed: job.seed ?? 0) : nil)
        let url = job.outputDir.appending(path: "mesh.glb")
        try tuft.glb().write(to: url)
        var effective = mapped.effective
        effective["x-gaea.demo.head_bone"] = .string(head.name)
        return RunResult(outputs: [.file("mesh", url, mediaType: "model/gltf-binary")], effective: effective)
    }
}

/// The body's head bone: its name and where it is in the body's own coordinates.
struct DemoBody {
    var name: String
    var position: SIMD3<Float>

    /// VRM 1.0's `VRMC_vrm` humanoid, VRM 0.x's `VRM` humanoid, else a node whose name ends in `head`.
    static func head(_ glb: Data) throws -> DemoBody {
        func refuse(_ why: String) -> GPPError { GPPError(.invalidRequest, why, detail: ["param": "body"]) }
        let d = Data(glb)
        func u32(_ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 | Int(d[i + 2]) << 16 | Int(d[i + 3]) << 24 }
        guard d.count >= 20, d[0..<4] == Data("glTF".utf8), u32(16) == 0x4E4F_534A, 20 + u32(12) <= d.count,
              let json = try? JSONSerialization.jsonObject(with: d[20..<20 + u32(12)]) as? [String: Any],
              let nodes = json["nodes"] as? [[String: Any]] else { throw refuse("The body isn't a GLB with nodes.") }
        let extensions = json["extensions"] as? [String: Any] ?? [:]
        var index: Int?
        if let bones = ((extensions["VRMC_vrm"] as? [String: Any])?["humanoid"] as? [String: Any])?["humanBones"] as? [String: Any] {
            index = (bones["head"] as? [String: Any])?["node"] as? Int
        } else if let bones = ((extensions["VRM"] as? [String: Any])?["humanoid"] as? [String: Any])?["humanBones"] as? [[String: Any]] {
            index = bones.first { $0["bone"] as? String == "head" }?["node"] as? Int
        }
        index = index ?? nodes.firstIndex { ($0["name"] as? String ?? "").lowercased().hasSuffix("head") }
        guard let index, nodes.indices.contains(index) else { throw refuse("The body has no head bone the demo can find.") }

        func local(_ node: [String: Any]) -> simd_float4x4 {
            func floats(_ key: String) -> [Float]? { (node[key] as? [NSNumber])?.map(\.floatValue) }
            if let m = floats("matrix"), m.count == 16 {
                return simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                               SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
            }
            var out = matrix_identity_float4x4
            if let t = floats("translation"), t.count == 3 { out.columns.3 = SIMD4(t[0], t[1], t[2], 1) }
            if let r = floats("rotation"), r.count == 4 { out = out * simd_float4x4(simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])) }
            if let s = floats("scale"), s.count == 3 { out = out * simd_float4x4(diagonal: SIMD4(s[0], s[1], s[2], 1)) }
            return out
        }
        var parent: [Int: Int] = [:]
        for (i, node) in nodes.enumerated() { for child in node["children"] as? [Int] ?? [] { parent[child] = i } }
        var world = local(nodes[index]), at = index, hops = 0
        while let up = parent[at], hops < nodes.count { world = local(nodes[up]) * world; at = up; hops += 1 }
        let p = world.columns.3
        return DemoBody(name: nodes[index]["name"] as? String ?? "Head", position: SIMD3(p.x, p.y, p.z))
    }
}

/// The tuft: a square ring at the head bone's height + 10 cm, a narrower one 8 cm higher, and a tip 8 cm above that,
/// leaning back a little. Ring 0 follows the head, ring 1 and the tip the first chain joint.
struct DemoTuft {
    var head: DemoBody
    var halfWidth: Float
    var springs: Bool
    /// The texture's colour, or nil for a plain material (`texture: none`).
    var color: (UInt8, UInt8, UInt8)?

    static func color(seed: UInt64) -> (UInt8, UInt8, UInt8) {
        var rng = SplitMix64(seed)
        let v = rng.next()
        return (UInt8(64 + (v & 0x7F)), UInt8(64 + ((v >> 8) & 0x7F)), UInt8(64 + ((v >> 16) & 0x7F)))
    }

    func glb() throws -> Data {
        let o = head.position
        let joint0 = o + SIMD3(0, 0.10, 0), joint1 = o + SIMD3(0, 0.18, -0.02), tip = o + SIMD3(0, 0.26, -0.05)
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], joints: [UInt16] = []
        for (centre, half, joint, v) in [(joint0, halfWidth, UInt16(0), Float(1)), (joint1, halfWidth * 0.6, UInt16(1), Float(0.5))] {
            for (k, corner) in [SIMD3<Float>(-1, 0, -1), SIMD3(1, 0, -1), SIMD3(1, 0, 1), SIMD3(-1, 0, 1)].enumerated() {
                positions.append(centre + corner * half)
                normals.append(simd_normalize(corner))
                uvs.append(SIMD2(Float(k) / 3, v))
                joints.append(springs ? joint : 0)
            }
        }
        positions.append(tip); normals.append(SIMD3(0, 1, 0)); uvs.append(SIMD2(0.5, 0)); joints.append(springs ? 1 : 0)
        var indices: [UInt16] = []
        for k in 0..<4 {
            let a = UInt16(k), b = UInt16((k + 1) % 4)
            indices += [a, a + 4, b, b, a + 4, b + 4, a + 4, 8, b + 4]
        }

        var bin = Data(), views: [[String: Any]] = [], accessors: [[String: Any]] = []
        func add<T>(_ values: [T], type: String, component: Int, target: Int?, extra: [String: Any] = [:]) -> Int {
            while bin.count % 4 != 0 { bin.append(0) }
            let start = bin.count
            values.withUnsafeBufferPointer { bin.append(Data(buffer: $0)) }
            var view: [String: Any] = ["buffer": 0, "byteOffset": start, "byteLength": bin.count - start]
            if let target { view["target"] = target }
            views.append(view)
            let per = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16][type]!
            let scalars = (bin.count - start) / (component == 5126 ? 4 : 2)
            accessors.append(["bufferView": views.count - 1, "componentType": component, "count": scalars / per, "type": type]
                .merging(extra) { $1 })
            return accessors.count - 1
        }
        func flat(_ v: [SIMD3<Float>]) -> [Float] { v.flatMap { [$0.x, $0.y, $0.z] } }
        let lo = positions.reduce(positions[0]) { simd_min($0, $1) }, hi = positions.reduce(positions[0]) { simd_max($0, $1) }
        var attributes: [String: Any] = [
            "POSITION": add(flat(positions), type: "VEC3", component: 5126, target: 34962,
                            extra: ["min": [lo.x, lo.y, lo.z], "max": [hi.x, hi.y, hi.z]]),
            "NORMAL": add(flat(normals), type: "VEC3", component: 5126, target: 34962),
            "JOINTS_0": add(joints.flatMap { [$0, 0, 0, 0] }, type: "VEC4", component: 5123, target: 34962),
            "WEIGHTS_0": add(positions.flatMap { _ in [Float(1), 0, 0, 0] }, type: "VEC4", component: 5126, target: 34962),
        ]
        var material: [String: Any] = ["name": "DemoTuft", "doubleSided": true,
                                       "pbrMetallicRoughness": ["baseColorFactor": [0.8, 0.8, 0.8, 1], "metallicFactor": 0, "roughnessFactor": 1]]
        var json: [String: Any] = ["asset": ["version": "2.0", "generator": "gaea-plugin-demo"], "scene": 0]
        if let color {
            attributes["TEXCOORD_0"] = add(uvs.flatMap { [$0.x, $0.y] }, type: "VEC2", component: 5126, target: 34962)
            let png = try Self.png(color)
            while bin.count % 4 != 0 { bin.append(0) }
            views.append(["buffer": 0, "byteOffset": bin.count, "byteLength": png.count])
            bin.append(png)
            json["images"] = [["bufferView": views.count - 1, "mimeType": "image/png"]]
            json["samplers"] = [["magFilter": 9728, "minFilter": 9728]]
            json["textures"] = [["source": 0, "sampler": 0]]
            material["pbrMetallicRoughness"] = ["baseColorTexture": ["index": 0], "metallicFactor": 0, "roughnessFactor": 1]
        }
        let primitive: [String: Any] = ["attributes": attributes, "indices": add(indices, type: "SCALAR", component: 5123, target: 34963),
                                        "material": 0, "mode": 4]

        // The skeleton: the head bone, named as the body's, at the body's head; the chain under it. No joint is turned,
        // so each inverse bind matrix is the joint's place taken away.
        var nodes: [[String: Any]] = [["name": head.name, "translation": [o.x, o.y, o.z]]]
        var places = [o]
        if springs {
            nodes[0]["children"] = [1]
            nodes.append(["name": "DemoTuft_00", "translation": [0, 0.10, 0] as [Float], "children": [2]])
            nodes.append(["name": "DemoTuft_end", "translation": [0, 0.08, -0.02] as [Float]])
            places += [joint0, joint1]
        }
        let inverse = places.flatMap { p -> [Float] in [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -p.x, -p.y, -p.z, 1] }
        let skin: [String: Any] = ["name": "DemoTuft", "skeleton": 0, "joints": Array(0..<places.count),
                                   "inverseBindMatrices": add(inverse, type: "MAT4", component: 5126, target: nil)]
        nodes.append(["name": "DemoTuft", "mesh": 0, "skin": 0])
        json["nodes"] = nodes
        json["scenes"] = [["nodes": [0, nodes.count - 1]]]
        json["meshes"] = [["name": "DemoTuft", "primitives": [primitive]]]
        json["materials"] = [material]
        json["skins"] = [skin]
        if springs {
            json["extensionsUsed"] = ["VRMC_springBone"]
            json["extensions"] = ["VRMC_springBone": [
                "specVersion": "1.0",
                "springs": [["name": "DemoTuft", "joints": [
                    ["node": 1, "hitRadius": 0.02, "stiffness": 1.0, "gravityPower": 0, "gravityDir": [0, -1, 0], "dragForce": 0.4],
                    ["node": 2],
                ]]],
            ]]
        }
        while bin.count % 4 != 0 { bin.append(0) }
        json["buffers"] = [["byteLength": bin.count]]
        json["bufferViews"] = views
        json["accessors"] = accessors

        var text = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        while text.count % 4 != 0 { text.append(0x20) }
        var out = Data("glTF".utf8)
        func append(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { out.append(contentsOf: $0) } }
        append(2); append(12 + 8 + text.count + 8 + bin.count)
        append(text.count); append(0x4E4F_534A); out.append(text)
        append(bin.count); append(0x004E_4942); out.append(bin)
        return out
    }

    /// A 2 × 2 PNG of one colour.
    static func png(_ color: (UInt8, UInt8, UInt8)) throws -> Data {
        let pixels = [UInt8](repeating: 0, count: 4).indices.flatMap { _ in [color.0, color.1, color.2] }
        let data = NSMutableData()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 6,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: 0),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw GPPError(.internal, "couldn't encode the tuft's texture") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw GPPError(.internal, "couldn't encode the tuft's texture") }
        return data as Data
    }
}
