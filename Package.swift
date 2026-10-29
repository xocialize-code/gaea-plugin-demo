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
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.1.0"),
        // The demo's matmul calls MLX itself; the kit's engine already pulls the same mlx-swift.
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.31.5"),
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
