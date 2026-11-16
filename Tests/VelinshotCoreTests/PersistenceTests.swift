import Foundation
import XCTest
@testable import VelinshotCore

final class PersistenceTests: XCTestCase {
    func testHistoryRoundTripRestoresOriginalAndEditableState() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        let image = makeImage(width: 80, height: 60) { x, y in (UInt8(x * 3), UInt8(y * 4), 30, 255) }
        var state = EditState()
        state.crop = CGRect(x: 10, y: 5, width: 40, height: 30)
        state.annotations = [Annotation(kind: .arrow, points: [CGPoint(x: 20, y: 10), CGPoint(x: 40, y: 30)])]
        let entry = try store.save(image: image, state: state)
        XCTAssertEqual(try store.entries(), [entry])
        let (restored, edit) = try store.load(entry)
        XCTAssertEqual(edit, state)
        XCTAssertEqual(pixel(restored, 30, 20), pixel(image, 30, 20))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 3)
    }

    func testHistoryEvictsOldestWholeEntriesAtCountCap() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory, maxEntries: 2)
        let image = makeImage(width: 20, height: 20) { _, _ in (255, 0, 0, 255) }
        let first = try store.save(image: image, state: plainState())
        let second = try store.save(image: image, state: plainState())
        let third = try store.save(image: image, state: plainState())
        XCTAssertEqual(Set(try store.entries().map(\.id)), Set([second.id, third.id]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(first.imageFile).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(first.stateFile).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 6)
    }

    func testHistoryTooLargeEntryLeavesNoPartialFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory, maxBytes: 1)
        let image = makeImage(width: 20, height: 20) { _, _ in (255, 0, 0, 255) }
        XCTAssertThrowsError(try store.save(image: image, state: plainState()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testHistoryByteCapEvictsOldestAndKeepsLatest() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = makeImage(width: 100, height: 80) { x, y in
            (UInt8(truncatingIfNeeded: x * 71 ^ y * 123), UInt8(truncatingIfNeeded: x * 43), UInt8(truncatingIfNeeded: y * 59), 255)
        }
        let initial = HistoryStore(directory: directory)
        _ = try initial.save(image: image, state: plainState())
        let bytes = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(0) { $0 + ((try $1.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) }
        let store = HistoryStore(directory: directory, maxBytes: bytes + 64)
        let latest = try store.save(image: image, state: plainState())
        XCTAssertEqual(try store.entries().map(\.id), [latest.id])
    }

    func testHistoryClearPreservesUnrelatedFilesAndRemovesDamagedOwnedMetadata() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        let image = makeImage(width: 20, height: 20) { _, _ in (255, 0, 0, 255) }
        _ = try store.save(image: image, state: plainState())
        let unrelated = directory.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: unrelated)
        try Data("bad metadata".utf8).write(to: directory.appendingPathComponent("\(UUID().uuidString).entry.json"))
        XCTAssertThrowsError(try store.entries())
        try store.clear()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["notes.txt"])
        XCTAssertEqual(try String(contentsOf: unrelated), "keep me")
    }

    func testHistoryRejectsTraversalAndExternalSymlinks() throws {
        let directory = temporaryDirectory()
        let outside = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: outside) }
        let store = HistoryStore(directory: directory)
        let id = UUID()
        let traversal = HistoryEntry(id: id, createdAt: Date(), imageFile: "../private.png", stateFile: "\(id.uuidString).state.json", width: 20, height: 20)
        XCTAssertThrowsError(try store.load(traversal)) {
            XCTAssertEqual($0 as? VelinshotError, .invalidHistoryPath)
        }
        let external = outside.appendingPathComponent("private.png")
        try Data("private".utf8).write(to: external)
        let imageName = "\(id.uuidString).png"
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(imageName), withDestinationURL: external)
        let linked = HistoryEntry(id: id, createdAt: Date(), imageFile: imageName, stateFile: "\(id.uuidString).state.json", width: 20, height: 20)
        XCTAssertThrowsError(try store.load(linked))
        XCTAssertThrowsError(try store.clear())
        XCTAssertEqual(try String(contentsOf: external), "private")
    }

    func testHistoryCorruptStateFailsWithoutLosingSource() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        let image = makeImage(width: 20, height: 20) { _, _ in (255, 0, 0, 255) }
        let entry = try store.save(image: image, state: plainState())
        try Data("damaged".utf8).write(to: directory.appendingPathComponent(entry.stateFile))
        XCTAssertThrowsError(try store.load(entry))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.imageFile).path))
    }

    func testPresetRoundTripAndAtomicReplacement() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PresetStore(fileURL: directory.appendingPathComponent("nested/presets.json"))
        XCTAssertEqual(try store.load(), [])
        let original = StylePreset(name: "Iris", style: CanvasStyle())
        try store.save([original])
        XCTAssertEqual(try store.load(), [original])
        let replacement = StylePreset(name: "Plain", style: CanvasStyle(padding: 0, background: .transparent))
        try store.save([replacement])
        XCTAssertEqual(try store.load(), [replacement])
    }

    func testCorruptAndInvalidPresetsProduceErrors() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("presets.json")
        let store = PresetStore(fileURL: file)
        try Data("damaged".utf8).write(to: file)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save([StylePreset(name: " ", style: CanvasStyle())]))
        let duplicate = StylePreset(name: "Iris", style: CanvasStyle())
        XCTAssertThrowsError(try store.save([duplicate, duplicate]))
        XCTAssertThrowsError(try store.save([StylePreset(name: "Bad", style: CanvasStyle(padding: -2))]))
    }

    func testHistoryUpdatePreservesSourceAndDoesNotCreateDuplicateEntry() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        let image = makeImage(width: 60, height: 40) { x, y in (UInt8(x * 3), UInt8(y * 4), 60, 255) }
        let entry = try store.save(image: image, state: plainState())
        let sourceBefore = try Data(contentsOf: directory.appendingPathComponent(entry.imageFile))
        var updated = plainState()
        updated.style.backgroundAssetID = UUID().uuidString
        updated.annotations = [Annotation(kind: .arrow, points: [.zero, CGPoint(x: 30, y: 20)])]
        try store.update(entry, state: updated)
        XCTAssertEqual(try store.entries(), [entry])
        XCTAssertEqual(try store.load(entry).1, updated)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(entry.imageFile)), sourceBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 3)
    }

    func testHistoryUpdateRejectsForgedEntryAndCorruptMetadataWithoutOverwritingEdit() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        let image = makeImage(width: 20, height: 20) { _, _ in (255, 0, 0, 255) }
        let entry = try store.save(image: image, state: plainState())
        let editURL = directory.appendingPathComponent(entry.stateFile)
        let editBefore = try Data(contentsOf: editURL)
        let forged = HistoryEntry(id: entry.id, createdAt: entry.createdAt, imageFile: "../outside.png",
                                  stateFile: entry.stateFile, width: entry.width, height: entry.height)
        XCTAssertThrowsError(try store.update(forged, state: EditState()))
        let mismatch = HistoryEntry(id: entry.id, createdAt: entry.createdAt, imageFile: entry.imageFile,
                                    stateFile: entry.stateFile, width: 19, height: entry.height)
        XCTAssertThrowsError(try store.update(mismatch, state: EditState()))
        try Data("damaged".utf8).write(to: directory.appendingPathComponent("\(entry.id.uuidString).entry.json"))
        XCTAssertThrowsError(try store.update(entry, state: EditState()))
        XCTAssertEqual(try Data(contentsOf: editURL), editBefore)
    }
}
