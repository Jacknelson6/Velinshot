import Foundation
import XCTest
@testable import VelinshotCore

final class BoundedSnapshotReaderTests: XCTestCase {
    func testStableFileUsesOneBulkReadAndOneEOFProbe() throws {
        let reader = ChunkReader(Data(0..<12))
        let data = try BoundedSnapshotReader.read(expectedSize: 12, limit: 32, readChunk: reader.read)
        XCTAssertEqual(data, Data(0..<12))
        XCTAssertEqual(reader.requests, [13, 21])
    }

    func testNilAndEmptyFirstReadsAreEOFWithoutAnotherRead() throws {
        for nilResult in [true, false] {
            var requests: [Int] = []
            let result = try BoundedSnapshotReader.read(expectedSize: 0, limit: 16) { count in
                requests.append(count); return nilResult ? nil : Data()
            }
            XCTAssertTrue(result.isEmpty)
            XCTAssertEqual(requests, [1])
        }
    }

    func testShortPositiveReadsContinueUntilEOF() throws {
        let payload = Data(0..<17), reader = ChunkReader(Data(0..<17), maximumChunk: 3)
        let result = try BoundedSnapshotReader.read(expectedSize: 17, limit: 32, readChunk: reader.read)
        XCTAssertEqual(result, payload)
        XCTAssertEqual(reader.requests.first, 18)
        XCTAssertGreaterThan(reader.requests.count, 2)
        XCTAssertTrue(reader.requests.allSatisfy { $0 > 0 && $0 <= 33 })
    }

    func testFileGrowingAfterStatStillReturnsOneBoundedFrozenValue() throws {
        let payload = Data(0..<16), reader = ChunkReader(Data(0..<16))
        let result = try BoundedSnapshotReader.read(expectedSize: 3, limit: 32, readChunk: reader.read)
        XCTAssertEqual(result, payload)
        XCTAssertEqual(reader.requests, [4, 29, 17])
    }

    func testExactlyAtLimitSucceedsAfterOneByteEOFProbe() throws {
        let payload = Data(0..<16), reader = ChunkReader(Data(0..<16))
        XCTAssertEqual(try BoundedSnapshotReader.read(expectedSize: 16, limit: 16, readChunk: reader.read), payload)
        XCTAssertEqual(reader.requests, [17, 1])
    }

    func testBulkReadRejectsOneByteBeyondLimit() {
        let reader = ChunkReader(Data(0..<17))
        XCTAssertThrowsError(try BoundedSnapshotReader.read(expectedSize: 16, limit: 16, readChunk: reader.read)) {
            XCTAssertEqual($0 as? VelinshotError, .imageTooLarge)
        }
        XCTAssertEqual(reader.requests, [17])
    }

    func testGrowthBeyondLimitRejectsBeforeAppendingSentinel() {
        let reader = ChunkReader(Data(0..<17))
        XCTAssertThrowsError(try BoundedSnapshotReader.read(expectedSize: 3, limit: 16, readChunk: reader.read)) {
            XCTAssertEqual($0 as? VelinshotError, .imageTooLarge)
        }
        XCTAssertEqual(reader.requests, [4, 13])
        XCTAssertEqual(reader.offset, 17)
    }

    func testReadErrorPropagatesWithoutPartialSuccess() {
        var calls = 0
        XCTAssertThrowsError(try BoundedSnapshotReader.read(expectedSize: 10, limit: 16) { _ in
            calls += 1
            if calls == 1 { return Data([1, 2]) }
            throw ReaderFailure.deliberate
        }) { XCTAssertEqual($0 as? ReaderFailure, .deliberate) }
        XCTAssertEqual(calls, 2)
    }

    func testDeclaredOversizeRejectsBeforeAnyAllocationRead() {
        var calls = 0
        XCTAssertThrowsError(try BoundedSnapshotReader.read(expectedSize: Int.max, limit: 16) { _ in calls += 1; return Data() }) {
            XCTAssertEqual($0 as? VelinshotError, .imageTooLarge)
        }
        XCTAssertEqual(calls, 0)
    }
}

private enum ReaderFailure: Error, Equatable { case deliberate }
private final class ChunkReader {
    let payload: Data
    let maximumChunk: Int
    var offset = 0
    var requests: [Int] = []
    init(_ payload: Data, maximumChunk: Int = Int.max) { self.payload = payload; self.maximumChunk = maximumChunk }
    func read(_ count: Int) -> Data? {
        requests.append(count)
        guard offset < payload.count else { return nil }
        let end = min(payload.count, offset + min(count, maximumChunk))
        defer { offset = end }
        return payload.subdata(in: offset..<end)
    }
}
