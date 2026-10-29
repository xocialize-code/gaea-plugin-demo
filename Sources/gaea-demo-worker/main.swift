import CoreGraphics
import Foundation
import GaeaPluginKit
import GaeaProtocol
import ImageIO
import MLX
import MLXToolKit
import UniformTypeIdentifiers

// The Gaea demo plugin: a GPU matmul loop that proves the plugin path end to end (download, verify,
// launch, run, cancel), and a GPU gradient that answers MES `image.generate` with real PNGs, so a
// host can be checked with an offer that returns images (AB-T-0364). It started as the plugin-exec
// spike's worker; the matmul helper is xocialize-code/gaea examples/v1/manifest/demo.json.
//
// To make a plugin of your own from this template: change the identity below, replace
// `demo-matmul` with your models (`.engine(YourPackage.self, …)` for an MLXEngine package), and
// declare what it offers. `scripts/build-plugin.sh` writes manifest.json from this file.

/// The demo's one lane ships no weights: the operands live for one run.
struct Bundled: PackageConfiguration, BundledWeightSourcing {
    var bundledWeightSources: [BundledWeightSource] { [] }
}

/// What the host schedules from: n×n fp32 operands, measured at a 2.37 GB peak by the spike
/// (Spikes/plugin-exec/README.md, check 5). Nothing stays resident between runs.
let matmulManifest = PackageManifest(
    license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
    provenance: Provenance(sourceRepo: "xocialize-code/gaea-plugin-demo", revision: "0.3.0", tier: 1),
    requirements: RequirementsManifest(
        footprints: [QuantFootprint(quant: .fp32, residentBytes: 0, peakActivationBytes: 2_370_000_000)],
        requiredBackends: [.metalGPU]),
    surfaces: [])

/// `x-gaea.demo.matmul`: n×n fp32 matmul, repeated, with an optional `holdBytes` allocation so the
/// host can watch the worker's footprint rise and fall.
final class MatmulModel: PluginModel, @unchecked Sendable {
    func prepare(lane: LaneDefinition, context: WorkerContext) async throws {}

    func unload() async {
        Memory.clearCache()
    }

    func run(_ job: Job, context: RunContext) async throws -> RunResult {
        let n = job.param("n")?.intValue ?? 4096
        let iterations = job.param("iterations")?.intValue ?? 10
        let holdBytes = job.param("holdBytes")?.intValue ?? 0
        guard (16...16384).contains(n), (1...1000).contains(iterations), holdBytes >= 0 else {
            throw GPPError(.invalidRequest, "n is 16–16384, iterations 1–1000, holdBytes ≥ 0.")
        }
        if let seed = job.seed { MLXRandom.seed(seed) }

        var hold: MLXArray?
        if holdBytes > 0 {
            hold = MLXArray.zeros([holdBytes / 4], type: Float.self) + 1
            eval(hold!)
        }
        let b = MLXRandom.normal([n, n])
        var c = MLXRandom.normal([n, n])
        for step in 1...iterations {
            try context.checkCancellation()
            c = matmul(c, b) / Float(n).squareRoot()
            eval(c)
            context.progress("matmul", step: step, of: iterations)
        }
        let checksum = c.sum().item(Float.self)
        let held = hold.map { $0.sum().item(Float.self) } ?? 0
        hold = nil
        return RunResult(
            outputs: [.value("checksum", ["device": .string("\(Device.defaultDevice())"),
                                          "checksum": .double(Double(checksum)),
                                          "held_elements": .double(Double(held))])],
            effective: ["n": .int(Int64(n)), "iterations": .int(Int64(iterations)),
                        "holdBytes": .int(Int64(holdBytes))])
    }
}

/// The gradient renders one size×size image at a time; the largest, 2048², peaks well under 0.2 GB.
let gradientManifest = PackageManifest(
    license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
    provenance: Provenance(sourceRepo: "xocialize-code/gaea-plugin-demo", revision: "0.3.0", tier: 1),
    requirements: RequirementsManifest(
        footprints: [QuantFootprint(quant: .fp32, residentBytes: 0, peakActivationBytes: 200_000_000)],
        requiredBackends: [.metalGPU]),
    // The surface its lane backs, so the manifest ties the image.generate offer to this model (GPP-1 §4.7).
    surfaces: [ToolDescriptor(name: "demo_gradient", capability: .textToImage,
                              summary: "A two-colour GPU gradient: a smoke test for a host's image path, not a generative model.")])

/// MES `image.generate`, the smallest honest way: a two-colour linear gradient computed on the GPU,
/// its colours from the seed and the prompt, written as PNG under `output_dir`. `count` images, each
/// with seed + i (Image profile §2); `size` snaps down to a multiple of 8 (`size_snapped`).
final class GradientModel: PluginModel, @unchecked Sendable {
    func prepare(lane: LaneDefinition, context: WorkerContext) async throws {}

    func unload() async {
        Memory.clearCache()
    }

    func run(_ job: Job, context: RunContext) async throws -> RunResult {
        guard job.operation == "image.generate" else {
            throw GPPError(.unsupportedOperation, "demo-gradient only generates.")
        }
        let size = job.param("size")
        let asked = (width: size?["width"]?.intValue ?? 512, height: size?["height"]?.intValue ?? 512)
        guard (8...2048).contains(asked.width), (8...2048).contains(asked.height) else {
            throw GPPError(.invalidRequest, "size is 8–2048 on each side.")
        }
        let width = asked.width / 8 * 8, height = asked.height / 8 * 8
        let count = job.param("count")?.intValue ?? 1
        guard (1...8).contains(count) else { throw GPPError(.invalidRequest, "count is 1–8.") }
        let angle = job.param("x-gaea.gradient_angle")?.doubleValue ?? 45
        let prompt = try job.input("prompt").map { try String(contentsOf: $0, encoding: .utf8) } ?? ""
        let seed = Int(job.seed ?? 0)

        var outputs: [Output] = []
        for i in 0..<count {
            try context.checkCancellation()
            // Two colours from the seed and the prompt: the same request gives the same bytes.
            var rng = SplitMix64(UInt64(seed + i) ^ UInt64(truncatingIfNeeded: prompt.utf8.reduce(5381) { $0 &* 33 &+ Int($1) }))
            let from = MLXArray((0..<3).map { _ in Float(rng.next() % 256) })
            let to = MLXArray((0..<3).map { _ in Float(rng.next() % 256) })
            let radians = Float(angle * .pi / 180)
            let xs = MLXArray((0..<width).map(Float.init)) / Float(max(width - 1, 1))
            let ys = MLXArray((0..<height).map(Float.init)) / Float(max(height - 1, 1))
            let t = clip((xs.reshaped([1, width]) * cos(radians) + ys.reshaped([height, 1]) * sin(radians))
                         / (abs(cos(radians)) + abs(sin(radians))), min: 0, max: 1)
            let rgb = from.reshaped([1, 1, 3]) + (to - from).reshaped([1, 1, 3]) * t.expandedDimensions(axis: -1)
            let pixels = MLX.round(rgb).asType(.uint8)
            eval(pixels)
            let url = job.outputDir.appending(path: "image-\(i).png")
            try writePNG(pixels.asArray(UInt8.self), width: width, height: height, to: url)
            outputs.append(.file("images", url, mediaType: "image/png"))
            context.progress("render", step: i + 1, of: count)
        }
        var warnings: [Warning] = []
        if width != asked.width || height != asked.height {
            warnings.append(Warning(code: "size_snapped", message: "Snapped \(asked.width)×\(asked.height) to \(width)×\(height), a multiple of 8.",
                                    param: "size"))
        }
        return RunResult(
            outputs: outputs,
            effective: ["size": ["width": .int(Int64(width)), "height": .int(Int64(height))], "count": .int(Int64(count)),
                        "seed": .int(Int64(seed)), "x-gaea.gradient_angle": .double(angle)],
            warnings: warnings)
    }

    func writePNG(_ bytes: [UInt8], width: Int, height: Int, to url: URL) throws {
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: 0),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw GPPError(.internal, "couldn't encode a PNG") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw GPPError(.internal, "couldn't write \(url.path)") }
    }
}

/// A small, seedable generator, so the gradient's colours don't depend on the platform's RNG.
struct SplitMix64 {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

let demo = GaeaPluginDefinition(
    id: "com.xocialize.gaea.demo",
    version: "0.3.0",
    minGaea: "0.2.0",
    team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize-code/gaea-plugin-demo",
    title: "Gaea demo worker",
    summary: "A GPU matmul loop that proves the plugin path end to end (download, verify, launch, run, cancel), and a GPU gradient for image.generate.",
    license: "Apache-2.0",
    executable: "gaea-demo-worker",
    models: [
        .custom(id: "demo-matmul", title: "Demo matmul (GPU smoke test)", manifest: matmulManifest,
                lanes: [LaneDefinition(id: "fp32", default: true, configuration: Bundled())],
                make: { MatmulModel() }),
        .custom(id: "demo-gradient", title: "Demo gradient (image.generate smoke test)", manifest: gradientManifest,
                lanes: [LaneDefinition(id: "fp32", default: true, configuration: Bundled())],
                make: { GradientModel() }),
    ],
    offers: [
        PluginManifest.Offer(
            operation: "image.generate", profile: "image",
            model: [
                "id": "demo-gradient", "title": "Demo gradient",
                "license": ["spdx": "Apache-2.0", "commercial_use": true, "terms_url": "https://www.apache.org/licenses/LICENSE-2.0"],
                "memory_class": "small", "speed_class": "fast", "quality_tiers": ["draft", "standard", "best"],
                "notes": "A GPU-computed two-colour gradient, not a generative model: it checks a host's image path. Colours come from the seed and the prompt.",
            ],
            params: [
                "type": "object",
                "properties": [
                    "x-gaea.gradient_angle": ["type": "number", "minimum": 0, "maximum": 360, "default": 45,
                                              "description": "The gradient's direction, in degrees.",
                                              "x-mes-ui": ["widget": "slider", "label": "Angle"]],
                ],
                "additionalProperties": false,
            ],
            limits: PluginManifest.Limits(maxPixels: 4_194_304, minSide: 8, maxSide: 2048, sizeMultiple: 8)),
    ],
    helpers: [
        PluginManifest.Helper(
            operation: "x-gaea.demo.matmul", model: "demo-matmul", title: "Matmul smoke test",
            summary: "n×n fp32 matmul, repeated; holds holdBytes to exercise the memory ledger.",
            params: [
                "type": "object",
                "properties": [
                    "n": ["type": "integer", "minimum": 16, "maximum": 16384, "default": 4096],
                    "iterations": ["type": "integer", "minimum": 1, "maximum": 1000, "default": 10],
                    "holdBytes": ["type": "integer", "minimum": 0, "default": 0],
                ],
                "additionalProperties": false,
            ]),
    ])

await GaeaPluginMain.run(demo)
