import Foundation
import CoreGraphics

/// Desktop points use AppKit's bottom-left origin. Capture sources use top-left points.
public enum CaptureGeometry {
    public struct Display: Equatable {
        public let id: UInt32
        public let frame: CGRect
        public let scale: CGFloat
        public init(id: UInt32, frame: CGRect, scale: CGFloat) {
            self.id = id; self.frame = frame; self.scale = scale
        }
    }
    public struct Part {
        public let displayID: UInt32
        public let sourceRect: CGRect
        public let destinationRect: CGRect
        public let width: Int
        public let height: Int
    }
    public struct Plan {
        public let width: Int
        public let height: Int
        public let scale: CGFloat
        public let parts: [Part]
    }
    public enum Failure: Error { case invalidRegion, noDisplay, tooLarge }

    public static func selection(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
    public static func quartzPoint(_ point: CGPoint, primaryMaxY: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryMaxY - point.y)
    }
    public static func cocoaRect(_ rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryMaxY - rect.maxY, width: rect.width, height: rect.height)
    }
    public static func plan(rect: CGRect, displays: [Display]) throws -> Plan {
        guard finite(rect), rect.width >= 1, rect.height >= 1,
              displays.allSatisfy({ finite($0.frame) && $0.scale.isFinite && $0.scale > 0 }) else {
            throw Failure.invalidRegion
        }
        let selected = displays.filter { $0.frame.intersects(rect) && !$0.frame.intersection(rect).isEmpty }
        guard !selected.isEmpty else { throw Failure.noDisplay }
        let scale = selected.map(\.scale).max() ?? 1
        let scaledWidth = (rect.width * scale).rounded(), scaledHeight = (rect.height * scale).rounded()
        guard scaledWidth <= 16384, scaledHeight <= 16384, scaledWidth * scaledHeight <= 40_000_000 else {
            throw Failure.tooLarge
        }
        let width = max(1, Int(scaledWidth)), height = max(1, Int(scaledHeight))
        let parts = selected.map { display -> Part in
            let part = display.frame.intersection(rect)
            // Round shared boundaries once so adjacent mixed-scale displays have no pixel seam.
            let left = ((part.minX - rect.minX) * scale).rounded()
            let bottom = ((part.minY - rect.minY) * scale).rounded()
            let right = ((part.maxX - rect.minX) * scale).rounded()
            let top = ((part.maxY - rect.minY) * scale).rounded()
            return Part(displayID: display.id,
                        sourceRect: CGRect(x: part.minX - display.frame.minX,
                                           y: display.frame.maxY - part.maxY,
                                           width: part.width, height: part.height),
                        destinationRect: CGRect(x: left, y: bottom, width: right - left, height: top - bottom),
                        width: max(1, Int(right - left)), height: max(1, Int(top - bottom)))
        }
        return Plan(width: width, height: height, scale: scale, parts: parts)
    }
    private static func finite(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
    }
}
