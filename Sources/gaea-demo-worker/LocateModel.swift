import CoreGraphics
import Foundation
import GaeaPluginKit
import GaeaProtocol
import ImageIO
import MLXToolKit

// `demo-locate`: a stand-in for MES `image.locate` (a picture and a prompt in, boxes out: Image §3.4, RFC 0010; Gaea
// AB-T-0483), so a host's locate path and the conformance suite can run without weights. It isn't a model and it
// doesn't read the prompt. It boxes each shape that stands out from the picture's border colour, the largest first.

/// One picture read at up to 256 px a side: well under 0.1 GB.
let locateManifest = PackageManifest(
    license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
    provenance: Provenance(sourceRepo: "xocialize-code/gaea-plugin-demo", revision: "0.6.0", tier: 1),
    requirements: RequirementsManifest(
        footprints: [QuantFootprint(quant: .fp32, residentBytes: 0, peakActivationBytes: 100_000_000)],
        requiredBackends: [.metalGPU]),
    surfaces: [ToolDescriptor(name: "demo_locate", capability: .imageAnalysis,
                              summary: "Boxes around the shapes that stand out from the border colour: a smoke test for a host's locate path, not a model.")])

/// The most boxes the stand-in returns, and the offer's `limits.max_count`.
let locateMaxBoxes = 8

final class LocateModel: PluginModel, @unchecked Sendable {
    func prepare(lane: LaneDefinition, context: WorkerContext) async throws {}
    func unload() async {}

    func run(_ job: Job, context: RunContext) async throws -> RunResult {
        guard job.operation == "image.locate" else { throw GPPError(.unsupportedOperation, "demo-locate only locates.") }
        guard let url = job.input("image") else { throw GPPError(.invalidRequest, "image.locate needs the picture.", detail: ["param": "image"]) }
        guard let prompt = try job.text("prompt"), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GPPError(.invalidRequest, "image.locate needs a prompt: what to find.", detail: ["param": "prompt"])
        }
        let count = job.param("count")?.intValue ?? 1
        guard (1...locateMaxBoxes).contains(count) else {
            throw GPPError(.invalidRequest, "count is 1–\(locateMaxBoxes).", detail: ["param": "count"])
        }
        let shapes = try DemoShapes.find(url)
        // The largest shape scores 1, the others by their area against it: descending, as §3.4 orders them.
        let largest = Double(shapes.first?.area ?? 1)
        let boxes: [JSONValue] = shapes.prefix(count).map { shape in
            ["x": .double(shape.x), "y": .double(shape.y), "width": .double(shape.width), "height": .double(shape.height),
             "label": .string(prompt), "score": .double((Double(shape.area) / largest * 1000).rounded() / 1000)]
        }
        return RunResult(outputs: [.value("boxes", .array(boxes))], effective: ["count": .int(Int64(count))])
    }
}

/// The shapes of a picture: connected regions (four neighbours) whose colour is far from the border's, as boxes in
/// shares of the upright picture, largest area first. A region under 0.2 % of the picture is noise and is left out.
enum DemoShapes {
    struct Shape { var x, y, width, height: Double; var area: Int }

    static func find(_ url: URL) throws -> [Shape] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw GPPError(.invalidRequest, "The picture isn't an image the demo can read.", detail: ["param": "image"])
        }
        // Read at up to 256 px a side: enough for a box, and a flood fill over at most 65,536 cells.
        let scale = min(1, 256 / Double(max(image.width, image.height)))
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw GPPError(.internal, "couldn't read the picture") }
        // On white, so a transparent background reads as the border does.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        func colour(_ i: Int) -> (Int, Int, Int) { (Int(pixels[i * 4]), Int(pixels[i * 4 + 1]), Int(pixels[i * 4 + 2])) }
        let border = colour(0)
        var stands = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            let c = colour(i)
            stands[i] = abs(c.0 - border.0) + abs(c.1 - border.1) + abs(c.2 - border.2) > 96
        }
        var seen = [Bool](repeating: false, count: w * h)
        var shapes: [Shape] = []
        var stack: [Int] = []
        for start in 0..<(w * h) where stands[start] && !seen[start] {
            var (minX, minY, maxX, maxY, area) = (w, h, -1, -1, 0)
            stack.append(start)
            seen[start] = true
            while let i = stack.popLast() {
                let (x, y) = (i % w, i / w)
                area += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                if x > 0, stands[i - 1], !seen[i - 1] { seen[i - 1] = true; stack.append(i - 1) }
                if x < w - 1, stands[i + 1], !seen[i + 1] { seen[i + 1] = true; stack.append(i + 1) }
                if y > 0, stands[i - w], !seen[i - w] { seen[i - w] = true; stack.append(i - w) }
                if y < h - 1, stands[i + w], !seen[i + w] { seen[i + w] = true; stack.append(i + w) }
            }
            guard area * 500 >= w * h else { continue }
            shapes.append(Shape(x: Double(minX) / Double(w), y: Double(minY) / Double(h),
                                width: Double(maxX - minX + 1) / Double(w), height: Double(maxY - minY + 1) / Double(h), area: area))
        }
        return shapes.sorted { $0.area > $1.area }
    }
}
