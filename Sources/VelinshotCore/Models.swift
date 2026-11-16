import AppKit
import Foundation

public struct RGBA: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if let value = UInt64(cleaned, radix: 16), cleaned.count == 6 || cleaned.count == 8 {
            let hasAlpha = cleaned.count == 8
            self.init(red: Double((value >> (hasAlpha ? 24 : 16)) & 255) / 255,
                      green: Double((value >> (hasAlpha ? 16 : 8)) & 255) / 255,
                      blue: Double((value >> (hasAlpha ? 8 : 0)) & 255) / 255,
                      alpha: hasAlpha ? Double(value & 255) / 255 : 1)
        } else {
            self.init(red: 0, green: 0, blue: 0)
        }
    }

    public init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        self.init(red: Double(rgb.redComponent), green: Double(rgb.greenComponent),
                  blue: Double(rgb.blueComponent), alpha: Double(rgb.alphaComponent))
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: clamped(red), green: clamped(green), blue: clamped(blue), alpha: clamped(alpha))
    }

    public var cgColor: CGColor { nsColor.cgColor }
    private func clamped(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
}

public enum AnnotationKind: String, Codable, CaseIterable, Sendable {
    case pen, line, arrow, rectangle, ellipse, text, highlighter, blur, redact, number
}

public struct Annotation: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: AnnotationKind
    public var points: [CGPoint]
    public var color: RGBA
    public var lineWidth: Double
    public var text: String
    public var fontSize: Double

    public init(id: UUID = UUID(), kind: AnnotationKind, points: [CGPoint],
                color: RGBA = RGBA(hex: "6757DA"), lineWidth: Double = 5,
                text: String = "", fontSize: Double = 28) {
        self.id = id
        self.kind = kind
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.text = text
        self.fontSize = fontSize
    }

    public var bounds: CGRect {
        guard let first = points.first else { return .zero }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        return CGRect(x: xs.min() ?? first.x, y: ys.min() ?? first.y,
                      width: (xs.max() ?? first.x) - (xs.min() ?? first.x),
                      height: (ys.max() ?? first.y) - (ys.min() ?? first.y))
    }
}

public enum BackgroundKind: String, Codable, CaseIterable, Sendable {
    case solid, gradient, image, transparent
}

public enum WatermarkPosition: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = WatermarkPosition(rawValue: value) ?? .bottomRight
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct CanvasStyle: Codable, Equatable, Sendable {
    public var padding: Double
    public var cornerRadius: Double
    public var shadow: Double
    public var background: BackgroundKind
    public var color1: RGBA
    public var color2: RGBA
    public var gradientAngle: Double
    public var ratioWidth: Double
    public var ratioHeight: Double
    public var outputScale: Double
    public var borderWidth: Double
    public var backgroundAssetID: String?
    public var inset: Double
    public var insetColor: RGBA
    public var fixedWidth: Int?
    public var fixedHeight: Int?
    public var autoBalance: Bool
    public var autoColor: Bool
    public var watermarkText: String
    public var watermarkFontSize: Double
    public var watermarkColor: RGBA
    public var watermarkPosition: WatermarkPosition

    public init(padding: Double = 64, cornerRadius: Double = 20, shadow: Double = 24,
                background: BackgroundKind = .gradient,
                color1: RGBA = RGBA(hex: "B7AEF8"), color2: RGBA = RGBA(hex: "E6E3FF"),
                gradientAngle: Double = 35, ratioWidth: Double = 0, ratioHeight: Double = 0,
                outputScale: Double = 1, borderWidth: Double = 0, backgroundAssetID: String? = nil,
                inset: Double = 0, insetColor: RGBA = RGBA(hex: "FFFFFF"),
                fixedWidth: Int? = nil, fixedHeight: Int? = nil,
                autoBalance: Bool = true, autoColor: Bool = false,
                watermarkText: String = "", watermarkFontSize: Double = 20,
                watermarkColor: RGBA = RGBA(red: 24.0 / 255, green: 26.0 / 255, blue: 36.0 / 255, alpha: 0.7),
                watermarkPosition: WatermarkPosition = .bottomRight) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.background = background
        self.color1 = color1
        self.color2 = color2
        self.gradientAngle = gradientAngle
        self.ratioWidth = ratioWidth
        self.ratioHeight = ratioHeight
        self.outputScale = outputScale
        self.borderWidth = borderWidth
        self.backgroundAssetID = backgroundAssetID
        self.inset = inset
        self.insetColor = insetColor
        self.fixedWidth = fixedWidth
        self.fixedHeight = fixedHeight
        self.autoBalance = autoBalance
        self.autoColor = autoColor
        self.watermarkText = watermarkText
        self.watermarkFontSize = watermarkFontSize
        self.watermarkColor = watermarkColor
        self.watermarkPosition = watermarkPosition
    }

    private enum CodingKeys: String, CodingKey {
        case padding, cornerRadius, shadow, background, color1, color2, gradientAngle
        case ratioWidth, ratioHeight, outputScale, borderWidth, backgroundAssetID
        case inset, insetColor, fixedWidth, fixedHeight, autoBalance, autoColor
        case watermarkText, watermarkFontSize, watermarkColor, watermarkPosition
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CanvasStyle()
        padding = try values.decodeIfPresent(Double.self, forKey: .padding) ?? defaults.padding
        cornerRadius = try values.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? defaults.cornerRadius
        shadow = try values.decodeIfPresent(Double.self, forKey: .shadow) ?? defaults.shadow
        background = try values.decodeIfPresent(BackgroundKind.self, forKey: .background) ?? defaults.background
        color1 = try values.decodeIfPresent(RGBA.self, forKey: .color1) ?? defaults.color1
        color2 = try values.decodeIfPresent(RGBA.self, forKey: .color2) ?? defaults.color2
        gradientAngle = try values.decodeIfPresent(Double.self, forKey: .gradientAngle) ?? defaults.gradientAngle
        ratioWidth = try values.decodeIfPresent(Double.self, forKey: .ratioWidth) ?? defaults.ratioWidth
        ratioHeight = try values.decodeIfPresent(Double.self, forKey: .ratioHeight) ?? defaults.ratioHeight
        outputScale = try values.decodeIfPresent(Double.self, forKey: .outputScale) ?? defaults.outputScale
        borderWidth = try values.decodeIfPresent(Double.self, forKey: .borderWidth) ?? defaults.borderWidth
        backgroundAssetID = try values.decodeIfPresent(String.self, forKey: .backgroundAssetID)
        inset = try values.decodeIfPresent(Double.self, forKey: .inset) ?? defaults.inset
        insetColor = try values.decodeIfPresent(RGBA.self, forKey: .insetColor) ?? defaults.insetColor
        fixedWidth = try values.decodeIfPresent(Int.self, forKey: .fixedWidth)
        fixedHeight = try values.decodeIfPresent(Int.self, forKey: .fixedHeight)
        autoBalance = try values.decodeIfPresent(Bool.self, forKey: .autoBalance) ?? defaults.autoBalance
        autoColor = try values.decodeIfPresent(Bool.self, forKey: .autoColor) ?? defaults.autoColor
        watermarkText = try values.decodeIfPresent(String.self, forKey: .watermarkText) ?? defaults.watermarkText
        watermarkFontSize = try values.decodeIfPresent(Double.self, forKey: .watermarkFontSize) ?? defaults.watermarkFontSize
        watermarkColor = try values.decodeIfPresent(RGBA.self, forKey: .watermarkColor) ?? defaults.watermarkColor
        watermarkPosition = try values.decodeIfPresent(WatermarkPosition.self, forKey: .watermarkPosition) ?? defaults.watermarkPosition
    }
}

public struct EditState: Codable, Equatable, Sendable {
    public var style: CanvasStyle
    public var annotations: [Annotation]
    public var crop: CGRect?

    public init(style: CanvasStyle = CanvasStyle(), annotations: [Annotation] = [], crop: CGRect? = nil) {
        self.style = style
        self.annotations = annotations
        self.crop = crop
    }
}

public struct RenderLayout: Equatable, Sendable {
    public let canvasSize: CGSize
    public let imageRect: CGRect
    public let cropRect: CGRect
    public let exportSize: CGSize
    public let panelRect: CGRect

    public init(canvasSize: CGSize, imageRect: CGRect, cropRect: CGRect, exportSize: CGSize, panelRect: CGRect? = nil) {
        self.canvasSize = canvasSize
        self.imageRect = imageRect
        self.cropRect = cropRect
        self.exportSize = exportSize
        self.panelRect = panelRect ?? imageRect
    }
}

public enum VelinshotError: LocalizedError, Equatable {
    case invalidImage(String)
    case imageTooLarge
    case invalidStyle(String)
    case invalidCrop
    case renderingFailed
    case encodingFailed
    case corruptHistory(String)
    case invalidHistoryPath
    case invalidPreset(String)

    public var errorDescription: String? {
        switch self {
        case .invalidImage(let reason): return "This image could not be opened. \(reason)"
        case .imageTooLarge: return "This image is too large. Use an image below 40 megapixels and 16,384 pixels per side, or reduce the export scale."
        case .invalidStyle(let reason): return "These appearance settings cannot be rendered. \(reason)"
        case .invalidCrop: return "The crop must contain at least one pixel inside the screenshot."
        case .renderingFailed: return "The screenshot could not be rendered. Try a smaller export size."
        case .encodingFailed: return "The image could not be encoded. Try another format."
        case .corruptHistory(let reason): return "A history item could not be restored. \(reason)"
        case .invalidHistoryPath: return "This history item refers to a file outside the history folder."
        case .invalidPreset(let reason): return "The saved presets could not be read. \(reason)"
        }
    }
}

public enum ImageLimits {
    public static let maximumPixels = 40_000_000
    public static let maximumDimension = 16_384

    public static func validate(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw VelinshotError.invalidImage("The dimensions are empty.") }
        guard width <= maximumDimension, height <= maximumDimension,
              width <= maximumPixels / height else { throw VelinshotError.imageTooLarge }
    }
}
