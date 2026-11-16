import CoreGraphics
import Foundation
import Vision

public struct RecognizedText: Equatable, Sendable {
    public let text: String
    public let rect: CGRect

    public init(text: String, rect: CGRect) {
        self.text = text
        self.rect = rect
    }
}

public enum TextRecognizer {
    public static func recognize(image: CGImage) throws -> [RecognizedText] {
        try ImageLimits.validate(width: image.width, height: image.height)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.005
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])
        let results = (request.results ?? []).compactMap { observation -> RecognizedText? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let rect = observation.boundingBox
            return RecognizedText(text: candidate.string,
                                  rect: CGRect(x: rect.minX * CGFloat(image.width),
                                               y: (1 - rect.maxY) * CGFloat(image.height),
                                               width: rect.width * CGFloat(image.width),
                                               height: rect.height * CGFloat(image.height)))
        }
        return results.sorted {
            if abs($0.rect.midY - $1.rect.midY) > min($0.rect.height, $1.rect.height) / 2 {
                return $0.rect.minY < $1.rect.minY
            }
            return $0.rect.minX < $1.rect.minX
        }
    }
}
