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
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.11.0"),
        // The demo's matmul calls MLX itself; the kit's engine already pulls the same mlx-swift.
        // The fleet's mlx-swift fork, as mlx-engine-swift 0.74.1 takes it (0.32.4: upstream 0.32.3 plus the _updateInternal
        // leak fix, ml-explore/mlx-swift#501; Gaea AB-D-0208). A root line naming ml-explore's URL would win and drop it.
        .package(url: "https://github.com/xocialize/mlx-swift", from: "0.32.4"),
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
