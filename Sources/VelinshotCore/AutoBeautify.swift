import AppKit
import CoreGraphics

public enum AutoBeautify {
    /// Selects a dominant visible edge palette color without mixing unrelated bins.
    /// Crop coordinates are in the original source's top-left pixel space.
    public static func suggestInsetColor(source: CGImage, crop: CGRect? = nil) -> RGBA {
        let white = RGBA(red: 1, green: 1, blue: 1)
        let visibleSource: CGImage
        if let crop {
            guard crop.origin.x.isFinite, crop.origin.y.isFinite,
                  crop.size.width.isFinite, crop.size.height.isFinite,
                  crop.size.width > 0, crop.size.height > 0, !crop.isInfinite else { return white }
            let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
            let clipped = crop.intersection(bounds).integral.intersection(bounds)
            guard !clipped.isNull, !clipped.isEmpty,
                  let image = source.cropping(to: clipped) else { return white }
            visibleSource = image
        } else {
            visibleSource = source
        }
        guard let sample = PixelSample(source: visibleSource, maximumDimension: 64) else { return white }

        struct Bin {
            var weight = 0
            var red = 0.0
            var green = 0.0
            var blue = 0.0
        }
        var bins: [UInt16: Bin] = [:]
        let band = max(1, min(sample.width, sample.height) / 8)
        func collect(edgesOnly: Bool) {
            for y in 0..<sample.height {
                for x in 0..<sample.width {
                    if edgesOnly && !(x < band || x >= sample.width - band ||
                                      y < band || y >= sample.height - band) { continue }
                    let pixel = sample.pixel(x: x, y: y)
                    let alpha = Int(pixel.3)
                    guard alpha >= 26 else { continue }
                    let red = min(1, max(0, Double(pixel.0) / Double(alpha)))
                    let green = min(1, max(0, Double(pixel.1) / Double(alpha)))
                    let blue = min(1, max(0, Double(pixel.2) / Double(alpha)))
                    func channel5(_ value: Double) -> UInt16 {
                        UInt16(min(255, max(0, Int((value * 255).rounded()))) >> 3)
                    }
                    let key = (channel5(red) << 10) | (channel5(green) << 5) | channel5(blue)
                    var bin = bins[key] ?? Bin()
                    bin.weight += alpha
                    bin.red += red * Double(alpha)
                    bin.green += green * Double(alpha)
                    bin.blue += blue * Double(alpha)
                    bins[key] = bin
                }
            }
        }
        collect(edgesOnly: true)
        if bins.isEmpty { collect(edgesOnly: false) }
        var winner = Bin()
        var winnerKey = UInt16.max
        for (key, bin) in bins {
            if bin.weight > winner.weight || (bin.weight == winner.weight && key < winnerKey) {
                winner = bin
                winnerKey = key
            }
        }
        guard winner.weight > 0 else { return white }
        let weight = Double(winner.weight)
        return RGBA(red: winner.red / weight, green: winner.green / weight,
                    blue: winner.blue / weight, alpha: 1)
    }

    public static func suggestColors(source: CGImage) -> (RGBA, RGBA) {
        guard let sample = PixelSample(source: source, maximumDimension: 64) else {
            return (RGBA(hex: "B7AEF8"), RGBA(hex: "E6E3FF"))
        }
        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        let edgeBand = max(1, min(sample.width, sample.height) / 8)
        for y in 0..<sample.height {
            for x in 0..<sample.width {
                // A fixed outer-eighth band reflects the screenshot's surround
                // instead of allowing a bright center element to dominate it.
                guard x < edgeBand || x >= sample.width - edgeBand ||
                      y < edgeBand || y >= sample.height - edgeBand else { continue }
                let pixel = sample.pixel(x: x, y: y)
                let alpha = Double(pixel.3) / 255
                guard alpha > 0.1 else { continue }
                red += Double(pixel.0) / max(1, Double(pixel.3)) * alpha
                green += Double(pixel.1) / max(1, Double(pixel.3)) * alpha
                blue += Double(pixel.2) / max(1, Double(pixel.3)) * alpha
                weight += alpha
            }
        }
        guard weight > 0 else { return (RGBA(hex: "B7AEF8"), RGBA(hex: "E6E3FF")) }
        let color = NSColor(srgbRed: red / weight, green: green / weight, blue: blue / weight, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if saturation < 0.08 { hue = 0.68 }
        let first = NSColor(calibratedHue: hue, saturation: min(0.38, max(0.15, saturation * 0.65)), brightness: 0.90, alpha: 1)
        let second = NSColor(calibratedHue: (hue + 0.04).truncatingRemainder(dividingBy: 1),
                             saturation: min(0.16, max(0.06, saturation * 0.3)), brightness: 1, alpha: 1)
        return (RGBA(first), RGBA(second))
    }

    public static func contentBounds(source: CGImage) -> CGRect? {
        // Seek exact boundaries at source resolution. Every omitted interior
        // pixel is already enclosed by proven extrema; no thumbnail can erase
        // a one-pixel mark. Uniform inputs still receive one complete scan.
        guard let sample = PixelSample(source: source) else { return nil }
        let corners = [sample.pixel(x: 0, y: 0), sample.pixel(x: sample.width - 1, y: 0),
                       sample.pixel(x: 0, y: sample.height - 1),
                       sample.pixel(x: sample.width - 1, y: sample.height - 1)]
        let reference = corners[0]
        let transparentBorder = corners.allSatisfy { $0.3 < 8 }
        guard transparentBorder || corners.allSatisfy({ distance($0, reference) < 10 }) else { return nil }
        func isContent(x: Int, y: Int) -> Bool {
            let pixel = sample.pixel(x: x, y: y)
            return transparentBorder ? pixel.3 > 8 : distance(pixel, reference) > 10
        }
        func rowHasContent(_ y: Int) -> Bool {
            for x in 0..<sample.width where isContent(x: x, y: y) { return true }
            return false
        }
        var minY = 0
        while minY < sample.height && !rowHasContent(minY) { minY += 1 }
        guard minY < sample.height else { return nil }
        var maxY = sample.height - 1
        while maxY > minY && !rowHasContent(maxY) { maxY -= 1 }
        func columnHasContent(_ x: Int) -> Bool {
            for y in minY...maxY where isContent(x: x, y: y) { return true }
            return false
        }
        var minX = 0
        while minX < sample.width && !columnHasContent(minX) { minX += 1 }
        var maxX = sample.width - 1
        while maxX > minX && !columnHasContent(maxX) { maxX -= 1 }
        // Preserve a small safety edge around anti-aliased content.
        let margin = 2
        let x = max(0, minX - margin), y = max(0, minY - margin)
        let right = min(sample.width, maxX + 1 + margin), bottom = min(sample.height, maxY + 1 + margin)
        let bounds = CGRect(x: x, y: y, width: right - x, height: bottom - y)
        let full = CGRect(x: 0, y: 0, width: sample.width, height: sample.height)
        guard bounds != full else { return nil }
        return bounds
    }

    private static func distance(_ a: (UInt8, UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8, UInt8)) -> Int {
        max(abs(Int(a.0) - Int(b.0)), abs(Int(a.1) - Int(b.1)), abs(Int(a.2) - Int(b.2)), abs(Int(a.3) - Int(b.3)))
    }
}

struct PixelSample {
    let width: Int
    let height: Int
    private let context: CGContext
    private let storage: UnsafePointer<UInt8>

    // Materialize bytes only for consumers that explicitly need an owned copy.
    // Color and content analysis read the retained bitmap directly instead of
    // allocating a second full-size buffer for every capture.
    var bytes: [UInt8] {
        withExtendedLifetime(context) {
            Array(UnsafeBufferPointer(start: storage, count: width * height * 4))
        }
    }

    init?(source: CGImage, maximumDimension: Int? = nil) {
        let scale = maximumDimension.map { min(1, Double($0) / Double(max(source.width, source.height))) } ?? 1
        width = max(1, Int((Double(source.width) * scale).rounded()))
        height = max(1, Int((Double(source.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        self.context = context
        storage = UnsafePointer(data.assumingMemoryBound(to: UInt8.self))
    }

    func pixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        // All callers traverse valid bitmap coordinates. The owning CGContext
        // stays alive through each read, including when a sample value is copied.
        withExtendedLifetime(context) {
            let offset = (y * width + x) * 4
            return (storage[offset], storage[offset + 1], storage[offset + 2], storage[offset + 3])
        }
    }
}
