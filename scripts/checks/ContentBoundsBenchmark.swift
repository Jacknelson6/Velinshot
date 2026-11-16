import AppKit
import CoreGraphics
import Darwin
import Foundation
import VelinshotCore

func fixture(width: Int, height: Int) throws -> CGImage {
    try ImageLimits.validate(width: width, height: height)
    guard let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw VelinshotError.renderingFailed
    }
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
    // A single-pixel mark must remain in the detected bounds. No downsampling.
    context.fill(CGRect(x: 1, y: 1, width: 1, height: 1))
    guard let image = context.makeImage() else { throw VelinshotError.renderingFailed }
    return image
}

guard CommandLine.arguments.count == 3,
      let width = Int(CommandLine.arguments[1]), let height = Int(CommandLine.arguments[2]) else {
    fatalError("Usage: ContentBoundsBenchmark width height")
}
let source = try fixture(width: width, height: height)
var milliseconds: [Double] = []
var bounds: CGRect?
for _ in 0..<3 {
    let started = ProcessInfo.processInfo.systemUptime
    bounds = autoreleasepool { AutoBeautify.contentBounds(source: source) }
    milliseconds.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
}
var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
let object: [String: Any] = [
    "width": width, "height": height, "pixels": width * height,
    "milliseconds": milliseconds, "medianMilliseconds": milliseconds.sorted()[1],
    "peakRSSBytes": Int(usage.ru_maxrss), "configuration": "release",
    "bounds": bounds.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] } ?? [:]
]
let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
