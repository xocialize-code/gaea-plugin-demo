// swift-tools-version: 6.2
import PackageDescription

// The Gaea demo plugin, and the template every Gaea plugin starts from: one worker executable built
// on GaeaPluginKit, packaged as a signed .gaeaplugin bundle by scripts/build-plugin.sh.
//
// GAEA_PLUGIN_KIT_PATH points the kit at a local checkout while you work on both.
let kitPath = Context.environment["GAEA_PLUGIN_KIT_PATH"]

let package = Package(
    name: "gaea-plugin-demo",
    platforms: [.macOS(.v26)], // mlx-engine-swift's MLXToolKit requires macOS 26
    dependencies: [
        kitPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.15.0"),
        // mlx-engine-swift 0.82.1, the first on the fleet's mlx-swift 0.33.1 (contract 1.66.0, which only adds imageLocate
        // to the 1.65.0 Gaea 1.9 decodes). Pinned exactly: a later 0.x could add fields to the worker's memory report
        // that GPP v1's closed schema doesn't carry, or a contract Gaea can't decode.
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", exact: "0.82.1"),
        // The fleet's mlx-swift fork, as mlx-engine-swift 0.82.1 takes it: 0.33.1 is upstream 0.33.0 with the vendored
        // MLX's head-dim-split SDPA routes off, which abort or give wrong attention on M5 (AB-D-0264, AB-R-1009). It
        // replaces the 0.32.4 leak-fix fork (AB-D-0208), whose fix upstream 0.33.0 carries. A root line naming
        // ml-explore's URL would win and drop the patch.
        .package(url: "https://github.com/xocialize/mlx-swift", exact: "0.33.1"),
    ],
    targets: [
        .executableTarget(
            name: "gaea-demo-worker",
            dependencies: [
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
    ]
)
