import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VelinshotCore

func cpuMilliseconds() -> Double {
    var value = rusage(); getrusage(RUSAGE_SELF, &value)
    return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) * 1000 + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1000
}
func peakRSS() -> Int { var value = rusage(); getrusage(RUSAGE_SELF, &value); return Int(value.ru_maxrss) }
func residentRSS() -> Int {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "rss=", "-p", String(getpid())]
    let pipe = Pipe(); process.standardOutput = pipe
    do { try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) * 1024
    } catch { return 0 }
}
func timed<T>(_ name: String, stages: inout [String: [String: Double]], operation: () throws -> T) rethrows -> T {
    let wall = ProcessInfo.processInfo.systemUptime, cpu = cpuMilliseconds()
    let result = try operation()
    stages[name] = ["elapsedMs": (ProcessInfo.processInfo.systemUptime - wall) * 1000, "cpuMs": cpuMilliseconds() - cpu]
    return result
}
func fixture(width: Int, height: Int, kind: String) throws -> CGImage {
    if kind == "noise" {
        var state: UInt32 = 0x9E3779B9
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            state = state &* 1664525 &+ 1013904223
            bytes[index] = UInt8(truncatingIfNeeded: state)
            bytes[index + 1] = UInt8(truncatingIfNeeded: state >> 8)
            bytes[index + 2] = UInt8(truncatingIfNeeded: state >> 16)
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if kind != "alpha" { context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height)) }
    context.setFillColor(NSColor(srgbRed: 0.12, green: 0.16, blue: 0.27, alpha: 1).cgColor)
    context.fill(CGRect(x: width / 20, y: height / 20, width: width * 9 / 10, height: height * 9 / 10))
    context.setFillColor(NSColor.white.cgColor)
    for row in 0..<12 {
        context.fill(CGRect(x: width / 10, y: height / 10 + row * max(1, height / 18), width: width * (5 + row % 3) / 10, height: max(1, height / 100)))
    }
    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(x: 1, y: 1, width: 1, height: 1))
    return context.makeImage()!
}
func createFixture(_ url: URL, width: Int, height: Int, kind: String) throws {
    let image = try fixture(width: width, height: height, kind: kind)
    let identifier = url.pathExtension == "png" ? UTType.png.identifier : url.pathExtension == "jpg" ? UTType.jpeg.identifier : UTType.heic.identifier
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, identifier as CFString, 1, nil) else { throw VelinshotError.encodingFailed }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw VelinshotError.encodingFailed }
}

func run(_ url: URL, iteration: Int) throws -> [String: Any] {
    var stages: [String: [String: Double]] = [:]
    let started = ProcessInfo.processInfo.systemUptime, startedCPU = cpuMilliseconds()
    #if PREPARED_IMAGE_PIPELINE
    let snapshot = try timed("snapshotMetadata", stages: &stages) { try ImageLoader.open(url: url) }
    let original = try timed("fullDecode", stages: &stages) { try snapshot.fullResolution() }
    #else
    let data = try timed("encodedRead", stages: &stages) { try Data(contentsOf: url) }
    _ = try timed("metadata", stages: &stages) { () -> [CFString: Any] in
        let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    }
    let original = try timed("fullDecode", stages: &stages) { try ImageLoader.load(data: data) }
    #endif
    let crop = timed("exactBalance", stages: &stages) { AutoBeautify.contentBounds(source: original) }
    let state = EditState(crop: crop)
    #if PREPARED_IMAGE_PIPELINE
    let proxy = try timed("sourcePreview", stages: &stages) { try ImageLoader.preview(image: original) }
    let rendered = try timed("firstRender", stages: &stages) { try CanvasRenderer.renderPreview(source: proxy, state: state) }
    #else
    let rendered = try timed("firstRender", stages: &stages) { try CanvasRenderer.render(source: original, state: state, previewMaxDimension: 1400) }
    #endif
    let preparationMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
    let preparationCPU = cpuMilliseconds() - startedCPU
    let preparationPeak = peakRSS()
    let retained = withExtendedLifetime((original, rendered)) { residentRSS() }
    var changed = state
    _ = try timed("threeStyleRenders", stages: &stages) { () -> CGImage in
        var latest = rendered
        for _ in 0..<3 {
            changed.style.padding += 1
            #if PREPARED_IMAGE_PIPELINE
            latest = try CanvasRenderer.renderPreview(source: proxy, state: changed)
            #else
            latest = try CanvasRenderer.render(source: original, state: changed, previewMaxDimension: 1400)
            #endif
        }
        return latest
    }
    // An encoded-source thumbnail is measured separately. The accepted app path
    // uses full decode once, then derives its cached proxy from that CGImage.
    #if PREPARED_IMAGE_PIPELINE
    _ = try timed("encodedThumbnailDiagnostic", stages: &stages) { try snapshot.preview() }
    #else
    _ = try timed("encodedThumbnailDiagnostic", stages: &stages) { () -> CGImage in
        let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)!
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1400] as CFDictionary)!
    }
    #endif
    return ["fixture": url.lastPathComponent, "iteration": iteration,
        "cache": iteration == 0 ? "fresh-process; OS cache uncontrolled" : "same-process repeat; OS cache uncontrolled",
        "sourceWidth": original.width, "sourceHeight": original.height,
        "preparationMs": preparationMs, "preparationCPUms": preparationCPU,
        "peakPreparationRSSBytes": preparationPeak, "retainedRSSBytesAtPreparedStage": retained,
        "stages": stages, "crop": crop.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] } ?? [:]]
}
let arguments = CommandLine.arguments
if arguments.count == 7 && arguments[1] == "fixture" {
    try createFixture(URL(fileURLWithPath: arguments[2]), width: Int(arguments[3])!, height: Int(arguments[4])!, kind: arguments[5])
} else if arguments.count == 3 && arguments[1] == "run" {
    for iteration in 0..<2 {
        let report = try autoreleasepool { try run(URL(fileURLWithPath: arguments[2]), iteration: iteration) }
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
} else { fatalError("Usage: PipelineBenchmark fixture path width height kind marker | run path") }
