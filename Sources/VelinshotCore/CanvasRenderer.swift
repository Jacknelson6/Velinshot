import AppKit
import CoreGraphics
import CoreImage

public enum CanvasRenderer {
    private static let blurContext = CIContext(options: [.cacheIntermediates: false])
    public static func layout(sourceSize: CGSize, state: EditState) throws -> RenderLayout {
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width >= 1, sourceSize.height >= 1,
              sourceSize.width <= CGFloat(ImageLimits.maximumDimension),
              sourceSize.height <= CGFloat(ImageLimits.maximumDimension) else {
            throw VelinshotError.imageTooLarge
        }
        try ImageLimits.validate(width: Int(sourceSize.width.rounded(.up)), height: Int(sourceSize.height.rounded(.up)))
        let style = state.style
        try validate(style)
        let sourceRect = CGRect(origin: .zero, size: sourceSize)
        let crop: CGRect
        if let requested = state.crop {
            guard finite(requested), requested.width > 0, requested.height > 0 else { throw VelinshotError.invalidCrop }
            let clipped = requested.standardized.intersection(sourceRect).integral.intersection(sourceRect)
            guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { throw VelinshotError.invalidCrop }
            crop = clipped
        } else {
            crop = sourceRect
        }
        let padding = CGFloat(style.padding)
        let inset = CGFloat(style.inset)
        let panelSize = CGSize(width: crop.width + inset * 2, height: crop.height + inset * 2)
        var width = ceil(panelSize.width + padding * 2)
        var height = ceil(panelSize.height + padding * 2)
        let ratio: CGFloat?
        if let fixedWidth = style.fixedWidth, let fixedHeight = style.fixedHeight {
            ratio = CGFloat(fixedWidth) / CGFloat(fixedHeight)
        } else if style.ratioWidth > 0 {
            ratio = CGFloat(style.ratioWidth / style.ratioHeight)
        } else {
            ratio = nil
        }
        if let ratio {
            if width / height < ratio { width = height * ratio } else { height = width / ratio }
        }
        // Fractional composition dimensions preserve an exact ratio. Their units
        // remain original source pixels, independent of the final raster size.
        let canvas = CGSize(width: width, height: height)
        let export: CGSize
        if let fixedWidth = style.fixedWidth, let fixedHeight = style.fixedHeight {
            export = CGSize(width: fixedWidth, height: fixedHeight)
        } else {
            export = CGSize(width: ceil(canvas.width * style.outputScale), height: ceil(canvas.height * style.outputScale))
        }
        guard export.width.isFinite, export.height.isFinite,
              export.width <= CGFloat(ImageLimits.maximumDimension), export.height <= CGFloat(ImageLimits.maximumDimension) else {
            throw VelinshotError.imageTooLarge
        }
        try ImageLimits.validate(width: Int(export.width), height: Int(export.height))
        let panel = CGRect(x: (canvas.width - panelSize.width) / 2, y: (canvas.height - panelSize.height) / 2,
                           width: panelSize.width, height: panelSize.height)
        return RenderLayout(canvasSize: canvas,
                            imageRect: CGRect(x: panel.minX + inset, y: panel.minY + inset,
                                              width: crop.width, height: crop.height),
                            cropRect: crop, exportSize: export, panelRect: panel)
    }

    public static func render(source: CGImage, state: EditState, backgroundImage: CGImage? = nil,
                              previewMaxDimension: Int? = nil) throws -> CGImage {
        try renderRaster(source: source, sourceSize: CGSize(width: source.width, height: source.height),
                         isProxy: false, state: state, backgroundImage: backgroundImage,
                         backgroundSourceSize: nil, previewMaxDimension: previewMaxDimension)
    }

    public static func renderPreview(source: ImagePreview, state: EditState, backgroundImage: CGImage? = nil,
                                     backgroundPreview: ImagePreview? = nil, maximumDimension: Int = 1400) throws -> CGImage {
        try renderRaster(source: source.bitmap, sourceSize: source.sourceSize, isProxy: true, state: state,
                         backgroundImage: backgroundPreview?.bitmap ?? backgroundImage,
                         backgroundSourceSize: backgroundPreview?.sourceSize, previewMaxDimension: maximumDimension)
    }

    private static func renderRaster(source: CGImage, sourceSize: CGSize, isProxy: Bool, state: EditState,
                                     backgroundImage: CGImage?, backgroundSourceSize: CGSize?,
                                     previewMaxDimension: Int?) throws -> CGImage {
        let layout = try layout(sourceSize: sourceSize, state: state)
        let fullScale = state.style.fixedWidth.map { CGFloat($0) / layout.canvasSize.width } ?? CGFloat(state.style.outputScale)
        var scale = fullScale
        var pixelWidth = Int(layout.exportSize.width)
        var pixelHeight = Int(layout.exportSize.height)
        if let maximum = previewMaxDimension {
            guard maximum > 0 else { throw VelinshotError.invalidStyle("Preview size must be positive.") }
            if CGFloat(maximum) < max(layout.exportSize.width, layout.exportSize.height) {
                scale = min(scale, CGFloat(maximum) / max(layout.canvasSize.width, layout.canvasSize.height))
                pixelWidth = max(1, min(maximum, Int(ceil(layout.canvasSize.width * scale - 1e-8))))
                pixelHeight = max(1, min(maximum, Int(ceil(layout.canvasSize.height * scale - 1e-8))))
            }
        }
        try ImageLimits.validate(width: pixelWidth, height: pixelHeight)
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw VelinshotError.renderingFailed
        }
        context.interpolationQuality = .high
        if state.style.background == .solid || (state.style.background == .image && backgroundImage == nil) {
            // Cover the complete integer bitmap before applying a fractional
            // composition transform. Preserve the selected color's alpha.
            context.setFillColor(state.style.color1.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        let canvasRect = CGRect(origin: .zero, size: layout.canvasSize)
        let bitmapRect = CGRect(x: 0, y: 0, width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
        drawBackground(state.style, image: backgroundImage, imageSourceSize: backgroundSourceSize,
                       rect: canvasRect, bitmapRect: bitmapRect, context: context)

        let radius = min(CGFloat(state.style.cornerRadius), min(layout.panelRect.width, layout.panelRect.height) / 2)
        let panelPath = ContinuousCorners.path(in:layout.panelRect,radius:radius)
        let innerRadius = max(0, radius - CGFloat(state.style.inset))
        let imagePath = ContinuousCorners.path(in:layout.imageRect,radius:innerRadius)
        if state.style.shadow > 0 {
            context.saveGState()
            context.addRect(canvasRect)
            context.addPath(panelPath)
            context.clip(using: .evenOdd)
            // Quartz shadow parameters use base-space pixels, so apply the
            // composition's raster scale explicitly for exports and previews.
            let shadowPixels = CGFloat(state.style.shadow) * scale
            context.setShadow(offset: CGSize(width: 0, height: shadowPixels * 0.28),
                              blur: shadowPixels, color: NSColor.black.withAlphaComponent(0.25).cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(panelPath)
            context.fillPath()
            context.restoreGState()
        }
        if state.style.inset > 0 {
            // Fill the inset ring without filling transparent source pixels.
            // With inset zero there is no new layer, preserving existing pixels.
            context.saveGState()
            context.addPath(panelPath)
            context.addPath(imagePath)
            context.setFillColor(state.style.insetColor.cgColor)
            context.drawPath(using: .eoFill)
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(imagePath)
        context.clip()
        if isProxy {
            // Map each proxy axis independently into the original coordinate
            // space. Clipping the full proxy avoids integer crop quantization.
            drawImage(source, in: CGRect(x: layout.imageRect.minX - layout.cropRect.minX,
                                        y: layout.imageRect.minY - layout.cropRect.minY,
                                        width: sourceSize.width, height: sourceSize.height), context: context)
        } else {
            guard let cropped = source.cropping(to: layout.cropRect) else { throw VelinshotError.invalidCrop }
            drawImage(cropped, in: layout.imageRect, context: context)
        }
        context.restoreGState()
        if state.style.borderWidth > 0 {
            context.saveGState()
            context.addPath(panelPath)
            context.setLineWidth(CGFloat(state.style.borderWidth))
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.65).cgColor)
            context.strokePath()
            context.restoreGState()
        }
        context.saveGState()
        context.clip(to: canvasRect)
        context.translateBy(x: layout.sourceOriginInCanvas.x, y: layout.sourceOriginInCanvas.y)
        let blurClip = ContinuousCorners.path(in:layout.cropRect,radius:innerRadius)
        try drawAnnotations(state.annotations, source: source, proxySourceSize: isProxy ? sourceSize : nil,
                            blurClip:blurClip, context: context)
        context.restoreGState()
        context.saveGState()
        // Watermark dimensions and 12px margins use final export pixels. The
        // preview applies the same geometry at its reduced raster scale.
        context.scaleBy(x: 1 / fullScale, y: 1 / fullScale)
        try drawWatermark(state.style, exportSize: layout.exportSize, context: context)
        context.restoreGState()
        guard let result = context.makeImage() else { throw VelinshotError.renderingFailed }
        return result
    }

    private static func validate(_ style: CanvasStyle) throws {
        let bounded: [(Double, ClosedRange<Double>, String)] = [
            (style.padding, 0...2048, "Padding"), (style.inset, 0...2048, "Inset"),
            (style.cornerRadius, 0...8192, "Rounding"),
            (style.shadow, 0...512, "Shadow"), (style.borderWidth, 0...128, "Border"),
            (style.watermarkFontSize, 1...512, "Watermark size")
        ]
        for (value, range, name) in bounded where !value.isFinite || !range.contains(value) {
            throw VelinshotError.invalidStyle("\(name) is outside the supported range.")
        }
        guard style.gradientAngle.isFinite else { throw VelinshotError.invalidStyle("Gradient angle must be finite.") }
        guard (style.fixedWidth == nil) == (style.fixedHeight == nil) else {
            throw VelinshotError.invalidStyle("Exact output size needs both width and height.")
        }
        if let width = style.fixedWidth, let height = style.fixedHeight {
            try ImageLimits.validate(width: width, height: height)
            return
        }
        guard style.outputScale.isFinite, (0.1...4).contains(style.outputScale) else {
            throw VelinshotError.invalidStyle("Export scale is outside the supported range.")
        }
        let natural = style.ratioWidth == 0 && style.ratioHeight == 0
        let custom = style.ratioWidth.isFinite && style.ratioHeight.isFinite &&
            style.ratioWidth > 0 && style.ratioHeight > 0 && style.ratioWidth <= 1000 && style.ratioHeight <= 1000
        guard natural || custom else { throw VelinshotError.invalidStyle("Choose a valid aspect ratio.") }
    }

    private static func finite(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
    }

    private static func drawWatermark(_ style: CanvasStyle, exportSize: CGSize, context: CGContext) throws {
        let text = style.watermarkText.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let margin: CGFloat = 12
        let available = CGSize(width: exportSize.width - margin * 2, height: exportSize.height - margin * 2)
        guard available.width > 0, available.height > 0 else {
            throw VelinshotError.invalidStyle("A watermark needs an output larger than 24 by 24 pixels.")
        }
        var visible = String(text.prefix(2000))
        var fontSize = CGFloat(style.watermarkFontSize)
        func measure(_ string: String, size: CGFloat) -> CGSize {
            (string as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold)])
        }
        var size = measure(visible, size: fontSize)
        fontSize *= min(1, available.height / max(1, size.height))
        size = measure(visible, size: fontSize)
        if size.width > available.width {
            // Keep long watermarks legible: shrink to eight pixels, then
            // truncate with an ellipsis rather than draw microscopic text.
            fontSize = max(min(8, fontSize), fontSize * available.width / max(1, size.width))
            let characters = Array(visible)
            let ellipsis = "…"
            var low = 0, high = characters.count
            while low < high {
                let middle = (low + high + 1) / 2
                let candidate = String(characters.prefix(middle)) + ellipsis
                if measure(candidate, size: fontSize).width <= available.width { low = middle } else { high = middle - 1 }
            }
            visible = String(characters.prefix(low)) + ellipsis
            let ellipsisWidth = measure(visible, size: fontSize).width
            if ellipsisWidth > available.width { fontSize *= available.width / ellipsisWidth }
        }
        size = measure(visible, size: fontSize)
        if size.height > available.height {
            fontSize *= available.height / size.height
            size = measure(visible, size: fontSize)
        }
        let left = style.watermarkPosition == .topLeft || style.watermarkPosition == .bottomLeft
        let top = style.watermarkPosition == .topLeft || style.watermarkPosition == .topRight
        let point = CGPoint(x: left ? margin : exportSize.width - margin - size.width,
                            y: top ? margin : exportSize.height - margin - size.height)
        drawText(visible, at: point, color: style.watermarkColor.nsColor, size: Double(fontSize), context: context)
    }

    private static func drawBackground(_ style: CanvasStyle, image: CGImage?, imageSourceSize: CGSize?,
                                       rect: CGRect, bitmapRect: CGRect, context: CGContext) {
        switch style.background {
        case .transparent: break
        case .solid:
            break // Filled once in device space before the composition transform.
        case .gradient:
            let colors = [style.color1.cgColor, style.color2.cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) else { return }
            let angle = style.gradientAngle * .pi / 180
            let dx = CGFloat(cos(angle))
            let dy = CGFloat(sin(angle))
            let distance = abs(dx) * rect.width / 2 + abs(dy) * rect.height / 2
            let center = CGPoint(x: rect.midX, y: rect.midY)
            context.drawLinearGradient(gradient,
                start: CGPoint(x: center.x - dx * distance, y: center.y - dy * distance),
                end: CGPoint(x: center.x + dx * distance, y: center.y + dy * distance),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .image:
            guard let image else { return } // Its fallback color was filled in device space.
            let sourceSize = imageSourceSize ?? CGSize(width: image.width, height: image.height)
            let scale = max(bitmapRect.width / sourceSize.width, bitmapRect.height / sourceSize.height)
            let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
            drawImage(image, in: CGRect(x: bitmapRect.midX - size.width / 2, y: bitmapRect.midY - size.height / 2,
                                       width: size.width, height: size.height), context: context)
        }
    }

    private static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func drawAnnotations(_ annotations: [Annotation], source: CGImage, proxySourceSize: CGSize?, blurClip:CGPath, context: CGContext) throws {
        guard annotations.count <= 10_000, annotations.reduce(0, { $0 + $1.points.count }) <= 1_000_000 else {
            throw VelinshotError.invalidStyle("There are too many annotations.")
        }
        for annotation in annotations {
            guard let first = annotation.points.first else { continue }
            guard annotation.points.count <= 250_000,
                  annotation.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) < 10_000_000 && abs($0.y) < 10_000_000 }),
                  annotation.lineWidth.isFinite, annotation.fontSize.isFinite else {
                throw VelinshotError.invalidStyle("An annotation contains invalid coordinates.")
            }
            let last = annotation.points.last ?? first
            let width = CGFloat(min(512, max(0.5, annotation.lineWidth)))
            let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                              width: abs(first.x - last.x), height: abs(first.y - last.y))
            context.saveGState()
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setStrokeColor(annotation.color.cgColor)
            context.setFillColor(annotation.color.cgColor)
            switch annotation.kind {
            case .pen, .highlighter:
                if annotation.kind == .highlighter {
                    context.setAlpha(0.3)
                    context.setBlendMode(.multiply)
                    context.setLineWidth(max(12, width * 4))
                }
                if annotation.points.count == 1 {
                    context.fillEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width))
                } else {
                    context.beginPath()
                    context.addLines(between: annotation.points)
                    context.strokePath()
                }
            case .line, .arrow:
                context.move(to: first)
                context.addLine(to: last)
                context.strokePath()
                if annotation.kind == .arrow {
                    let angle = atan2(last.y - first.y, last.x - first.x)
                    let length = max(15, width * 4)
                    context.move(to: CGPoint(x: last.x - cos(angle - .pi / 6) * length,
                                            y: last.y - sin(angle - .pi / 6) * length))
                    context.addLine(to: last)
                    context.addLine(to: CGPoint(x: last.x - cos(angle + .pi / 6) * length,
                                               y: last.y - sin(angle + .pi / 6) * length))
                    context.strokePath()
                }
            case .rectangle:
                context.stroke(rect)
            case .ellipse:
                context.strokeEllipse(in: rect)
            case .text:
                drawText(annotation.text, at: first, color: annotation.color.nsColor,
                         size: min(512, max(6, annotation.fontSize)), context: context)
            case .number:
                let diameter = CGFloat(max(24, min(512, annotation.fontSize * 1.55)))
                context.fillEllipse(in: CGRect(x: first.x - diameter / 2, y: first.y - diameter / 2,
                                              width: diameter, height: diameter))
                let string = annotation.text.isEmpty ? "1" : annotation.text
                let font = NSFont.systemFont(ofSize: diameter * 0.52, weight: .bold)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
                let size = (string as NSString).size(withAttributes: attributes)
                drawText(string, at: CGPoint(x: first.x - size.width / 2, y: first.y - size.height / 2),
                         color: .white, size: diameter * 0.52, context: context)
            case .redact:
                context.setAlpha(1)
                context.setBlendMode(.copy)
                let opaque = annotation.color.nsColor.withAlphaComponent(1)
                context.setFillColor(opaque.cgColor)
                context.fill(rect.integral)
            case .blur:
                context.addPath(blurClip);context.clip()
                if let proxySourceSize {
                    drawProxyBlur(source: source, sourceSize: proxySourceSize, rect: rect.integral,
                                  strength: max(8, width * 2), context: context)
                } else {
                    drawBlur(source: source, rect: rect.integral, strength: max(8, width * 2), context: context)
                }
            }
            context.restoreGState()
        }
    }

    private static func drawText(_ string: String, at point: CGPoint, color: NSColor, size: Double, context: CGContext) {
        guard !string.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: CGFloat(size), weight: .semibold),
            .foregroundColor: color
        ]
        (String(string.prefix(20_000)) as NSString).draw(at: point, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawBlur(source: CGImage, rect: CGRect, strength: CGFloat, context: CGContext) {
        let bounded = rect.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard !bounded.isNull, bounded.width >= 1, bounded.height >= 1,
              let crop = source.cropping(to: bounded) else { return }
        // Work near preview resolution when drawing a preview, rather than allocate a
        // full-resolution intermediate every time the user drags a blur region.
        let transform = context.ctm
        let targetScale = min(1, max(0.05, hypot(transform.a, transform.c)))
        let ci = CIImage(cgImage: crop).transformed(by: CGAffineTransform(scaleX: targetScale, y: targetScale))
        let extent = ci.extent
        let blurred = ci.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: strength * targetScale])
            .cropped(to: extent)
        let white = CIImage(color: CIColor.white).cropped(to: extent)
        let opaque = blurred.composited(over: white)
        guard let output = blurContext.createCGImage(opaque, from: extent) else { return }
        drawImage(output, in: bounded, context: context)
    }

    private static func drawProxyBlur(source: CGImage, sourceSize: CGSize, rect: CGRect, strength: CGFloat, context: CGContext) {
        let bounded = rect.intersection(CGRect(origin: .zero, size: sourceSize))
        guard !bounded.isNull, bounded.width > 0, bounded.height > 0 else { return }
        let targetScale = min(1, max(0.000001, hypot(context.ctm.a, context.ctm.c)))
        let mapped = CIImage(cgImage: source).transformed(by: CGAffineTransform(
            scaleX: sourceSize.width / CGFloat(source.width), y: sourceSize.height / CGFloat(source.height)))
        let region = CGRect(x: bounded.minX, y: sourceSize.height - bounded.maxY,
                            width: bounded.width, height: bounded.height)
        let proxy = mapped.cropped(to: region).transformed(by: CGAffineTransform(scaleX: targetScale, y: targetScale))
        let blurred = proxy.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: strength * targetScale])
            .cropped(to: proxy.extent)
        let opaque = blurred.composited(over: CIImage(color: CIColor.white).cropped(to: proxy.extent))
        guard let output = blurContext.createCGImage(opaque, from: proxy.extent) else { return }
        drawImage(output, in: bounded, context: context)
    }
}
