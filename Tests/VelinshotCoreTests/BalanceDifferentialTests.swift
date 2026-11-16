import AppKit
import XCTest
@testable import VelinshotCore

final class BalanceDifferentialTests: XCTestCase {
    func testBoundarySeekingMatchesBruteForceFor600SeededFixtures() {
        for seed in 0..<600 {
            let width = 1 + seed % 41, height = 1 + seed * 17 % 37, mode = seed % 9
            var random = UInt32(seed + 1)
            let source = makeImage(width: width, height: height) { x,y in
                random = random &* 1664525 &+ 1013904223
                let corner = (x == 0 || x == width-1) && (y == 0 || y == height-1)
                let transparent = mode == 6
                let background: (UInt8,UInt8,UInt8,UInt8) = transparent ? (0,0,0,0) : (245,245,245,255)
                if mode == 7 && x == 0 && y == 0 { return (255,0,0,255) }
                if corner || mode == 0 { return background }
                switch mode {
                case 1: return x > width/4 && x < width*3/4 && y > height/4 && y < height*3/4 ? (0,0,0,255) : background
                case 2: return x == width/2 && y == height/2 ? (0,0,0,255) : background
                case 3: return x == width/2 ? (0,0,0,255) : background
                case 4: return y == height/2 ? (0,0,0,255) : background
                case 5:
                    let value = UInt8(230 + random % 26); return (value,value,value,255)
                case 6:
                    let alpha = UInt8([0,7,8,9,128,255][Int(random % 6)]); return (alpha,0,0,alpha)
                default: return random % 7 == 0 ? (0,0,0,255) : background
                }
            }
            XCTAssertEqual(AutoBeautify.contentBounds(source: source), bruteForceBounds(source), "seed \(seed), \(width)x\(height)")
        }
    }

    func testEverySinglePixelPositionMatchesBruteForceWithOpaqueAndAlphaBorders() {
        for transparent in [false,true] {
            for markY in 0..<11 {
                for markX in 0..<13 {
                    let source = makeImage(width:13,height:11) { x,y in
                        if x == markX && y == markY { return (0,0,0,255) }
                        return transparent ? (0,0,0,0) : (255,255,255,255)
                    }
                    XCTAssertEqual(AutoBeautify.contentBounds(source:source),bruteForceBounds(source),"single pixel \(markX),\(markY)")
                }
            }
        }
    }
}

// The accepted pre-v3 algorithm is retained only as an independent test oracle.
// Production never materializes this second owned full-size byte array.
private func bruteForceBounds(_ source: CGImage) -> CGRect? {
    guard let sample = PixelSample(source:source) else { return nil }
    let bytes = sample.bytes, width = sample.width, height = sample.height
    func value(_ x:Int,_ y:Int)->[Int] { let index = (y*width+x)*4;return (0..<4).map{Int(bytes[index+$0])} }
    func distance(_ lhs:[Int],_ rhs:[Int])->Int { zip(lhs,rhs).map{pair in abs(pair.0-pair.1)}.max() ?? 0 }
    let corners = [value(0,0),value(width-1,0),value(0,height-1),value(width-1,height-1)]
    let reference = corners[0], transparent = corners.allSatisfy{$0[3]<8}
    guard transparent || corners.allSatisfy({distance($0,reference)<10}) else { return nil }
    var minX = width,minY = height,maxX = -1,maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let p = value(x,y)
            if transparent ? p[3]>8 : distance(p,reference)>10 {
                minX = min(minX,x);minY = min(minY,y);maxX = max(maxX,x);maxY = max(maxY,y)
            }
        }
    }
    guard maxX>=minX,maxY>=minY else { return nil }
    let x = max(0,minX-2),y = max(0,minY-2),right = min(width,maxX+3),bottom = min(height,maxY+3)
    let result = CGRect(x:x,y:y,width:right-x,height:bottom-y)
    return result == CGRect(x:0,y:0,width:width,height:height) ? nil : result
}
