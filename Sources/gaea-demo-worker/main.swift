import Foundation
import GaeaPluginKit
import GaeaProtocol
import MLX
import MLXToolKit

// The Gaea demo plugin: a GPU matmul loop that proves the plugin path end to end (download, verify,
// launch, run, cancel). It started as the plugin-exec spike's worker; the manifest is
// xocialize/gaea examples/v1/manifest/demo.json plus the `engine` every kit worker declares.
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
    provenance: Provenance(sourceRepo: "xocialize/gaea-plugin-demo", revision: "0.2.0", tier: 1),
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

let demo = GaeaPluginDefinition(
    id: "com.xocialize.gaea.demo",
    version: "0.2.0",
    team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize/gaea-plugin-demo",
    title: "Gaea demo worker",
    summary: "A GPU matmul loop that proves the plugin path end to end: download, verify, launch, run, cancel.",
    license: "Apache-2.0",
    executable: "gaea-demo-worker",
    models: [
        .custom(id: "demo-matmul", title: "Demo matmul (GPU smoke test)", manifest: matmulManifest,
                lanes: [LaneDefinition(id: "fp32", default: true, configuration: Bundled())],
                make: { MatmulModel() }),
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
