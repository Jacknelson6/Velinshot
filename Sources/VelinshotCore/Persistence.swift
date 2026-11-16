import CoreGraphics
import Foundation

public struct HistoryEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let imageFile: String
    public let stateFile: String
    public let width: Int
    public let height: Int

    public init(id: UUID, createdAt: Date, imageFile: String, stateFile: String, width: Int, height: Int) {
        self.id = id
        self.createdAt = createdAt
        self.imageFile = imageFile
        self.stateFile = stateFile
        self.width = width
        self.height = height
    }
}

public struct HistoryStore {
    public let directory: URL
    public let maxEntries: Int
    public let maxBytes: Int
    private let fileManager = FileManager.default

    public init(directory: URL, maxEntries: Int = 50, maxBytes: Int = 250_000_000) {
        self.directory = directory.standardizedFileURL
        self.maxEntries = max(1, min(500, maxEntries))
        self.maxBytes = max(1, maxBytes)
    }

    @discardableResult
    public func save(image: CGImage, state: EditState) throws -> HistoryEntry {
        try ensureDirectory()
        _ = try CanvasRenderer.layout(sourceSize: CGSize(width: image.width, height: image.height), state: state)
        let id = UUID()
        let entry = HistoryEntry(id: id, createdAt: Date(), imageFile: "\(id.uuidString).png",
                                 stateFile: "\(id.uuidString).state.json", width: image.width, height: image.height)
        let imageData = try ImageExporter.data(image: image, format: .png)
        let stateData = try JSONEncoder().encode(state)
        let entryData = try JSONEncoder().encode(entry)
        guard stateData.count <= 64_000_000, imageData.count + stateData.count + entryData.count <= maxBytes else {
            throw VelinshotError.corruptHistory("This screenshot exceeds the history storage limit. It can still be exported.")
        }
        let imageURL = try safeURL(entry.imageFile)
        let stateURL = try safeURL(entry.stateFile)
        let entryURL = try safeURL(metadataName(id))
        var created: [URL] = []
        do {
            try imageData.write(to: imageURL, options: .atomic); created.append(imageURL)
            try stateData.write(to: stateURL, options: .atomic); created.append(stateURL)
            // Metadata is the commit marker. A reader never sees half of a new entry.
            try entryData.write(to: entryURL, options: .atomic); created.append(entryURL)
            try enforceLimits()
            return entry
        } catch {
            for url in created { try? fileManager.removeItem(at: url) }
            throw error
        }
    }

    public func entries() throws -> [HistoryEntry] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let contents = try fileManager.contentsOfDirectory(at: directory,
                                                          includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                          options: [.skipsHiddenFiles])
        var entries: [HistoryEntry] = []
        for url in contents where url.lastPathComponent.hasSuffix(".entry.json") {
            do {
                let checked = try safeURL(url.lastPathComponent)
                let values = try checked.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 16_384 else {
                    throw VelinshotError.corruptHistory("Invalid history metadata.")
                }
                let entry = try JSONDecoder().decode(HistoryEntry.self, from: Data(contentsOf: checked))
                try validate(entry)
                guard url.lastPathComponent == metadataName(entry.id) else {
                    throw VelinshotError.corruptHistory("History metadata has the wrong identifier.")
                }
                entries.append(entry)
            } catch let error as VelinshotError {
                throw error
            } catch {
                throw VelinshotError.corruptHistory("The metadata is damaged. Clear history to remove damaged entries.")
            }
        }
        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    public func load(_ entry: HistoryEntry) throws -> (CGImage, EditState) {
        try validate(entry)
        let imageURL = try safeURL(entry.imageFile)
        let stateURL = try safeURL(entry.stateFile)
        do {
            let values = try stateURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 64_000_000 else {
                throw VelinshotError.corruptHistory("The edit data is invalid or too large.")
            }
            let image = try ImageLoader.load(url: imageURL)
            guard image.width == entry.width, image.height == entry.height else {
                throw VelinshotError.corruptHistory("The source image does not match its metadata.")
            }
            let state = try JSONDecoder().decode(EditState.self, from: Data(contentsOf: stateURL))
            _ = try CanvasRenderer.layout(sourceSize: CGSize(width: image.width, height: image.height), state: state)
            return (image, state)
        } catch let error as VelinshotError {
            throw error
        } catch {
            throw VelinshotError.corruptHistory("The source or edit data is missing or damaged.")
        }
    }

    public func update(_ entry: HistoryEntry, state: EditState) throws {
        try validate(entry)
        let metadataURL = try safeURL(metadataName(entry.id))
        let imageURL = try safeURL(entry.imageFile)
        let stateURL = try safeURL(entry.stateFile)
        do {
            let metadataValues = try metadataURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard metadataValues.isRegularFile == true, metadataValues.isSymbolicLink != true,
                  (metadataValues.fileSize ?? 0) <= 16_384 else {
                throw VelinshotError.corruptHistory("The history metadata is invalid.")
            }
            let stored = try JSONDecoder().decode(HistoryEntry.self, from: Data(contentsOf: metadataURL))
            guard stored == entry else { throw VelinshotError.corruptHistory("This history entry no longer matches its metadata.") }
            _ = try CanvasRenderer.layout(sourceSize: CGSize(width: entry.width, height: entry.height), state: state)
            let stateData = try JSONEncoder().encode(state)
            let imageValues = try imageURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard imageValues.isRegularFile == true, imageValues.isSymbolicLink != true,
                  stateData.count <= 64_000_000,
                  stateData.count + (imageValues.fileSize ?? 0) + (metadataValues.fileSize ?? 0) <= maxBytes else {
                throw VelinshotError.corruptHistory("The updated entry exceeds the history storage limit.")
            }
            try stateData.write(to: stateURL, options: .atomic)
            try enforceLimits()
        } catch let error as VelinshotError {
            throw error
        } catch {
            throw VelinshotError.corruptHistory("The history metadata or source is missing, damaged or unwritable.")
        }
    }

    public func clear() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        // Recognized names only. An unexpected user file in this directory is preserved.
        for url in contents where isOwnedName(url.lastPathComponent) {
            let checked = try safeURL(url.lastPathComponent)
            try fileManager.removeItem(at: checked)
        }
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func metadataName(_ id: UUID) -> String { "\(id.uuidString).entry.json" }

    private func validate(_ entry: HistoryEntry) throws {
        guard entry.imageFile == "\(entry.id.uuidString).png",
              entry.stateFile == "\(entry.id.uuidString).state.json", entry.createdAt.timeIntervalSince1970.isFinite else {
            throw VelinshotError.invalidHistoryPath
        }
        try ImageLimits.validate(width: entry.width, height: entry.height)
        _ = try safeURL(entry.imageFile)
        _ = try safeURL(entry.stateFile)
    }

    private func isOwnedName(_ name: String) -> Bool {
        for suffix in [".png", ".state.json", ".entry.json"] where name.hasSuffix(suffix) {
            let stem = String(name.dropLast(suffix.count))
            if let id = UUID(uuidString: stem), id.uuidString == stem { return true }
        }
        return false
    }

    private func safeURL(_ name: String) throws -> URL {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent,
              !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else {
            throw VelinshotError.invalidHistoryPath
        }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let candidate = directory.appendingPathComponent(name).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.deletingLastPathComponent() == root else { throw VelinshotError.invalidHistoryPath }
        return candidate
    }

    private func enforceLimits() throws {
        var items = try entries()
        var sizes: [UUID: Int] = [:]
        for item in items {
            let names = [item.imageFile, item.stateFile, metadataName(item.id)]
            sizes[item.id] = try names.reduce(0) { sum, name in
                let url = try safeURL(name)
                return sum + ((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            }
        }
        var total = sizes.values.reduce(0, +)
        while items.count > maxEntries || total > maxBytes {
            guard let oldest = items.popLast() else { break }
            for name in [metadataName(oldest.id), oldest.imageFile, oldest.stateFile] {
                let url = try safeURL(name)
                if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            }
            total -= sizes[oldest.id] ?? 0
        }
    }
}

public struct StylePreset: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var style: CanvasStyle

    public init(id: UUID = UUID(), name: String, style: CanvasStyle) {
        self.id = id
        self.name = name
        self.style = style
    }
}

public struct PresetStore {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> [StylePreset] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 1_000_000 else { throw VelinshotError.invalidPreset("The preset file is too large.") }
            let presets = try JSONDecoder().decode([StylePreset].self, from: Data(contentsOf: fileURL))
            try validate(presets)
            return presets
        } catch let error as VelinshotError {
            throw error
        } catch {
            throw VelinshotError.invalidPreset("The preset file is damaged or unreadable.")
        }
    }

    public func save(_ presets: [StylePreset]) throws {
        try validate(presets)
        let data = try JSONEncoder().encode(presets)
        guard data.count <= 1_000_000 else { throw VelinshotError.invalidPreset("The preset file is too large.") }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private func validate(_ presets: [StylePreset]) throws {
        guard presets.count <= 200, Set(presets.map(\.id)).count == presets.count,
              presets.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 120 }) else {
            throw VelinshotError.invalidPreset("Use unique presets with names of 1 to 120 characters.")
        }
        for preset in presets {
            // Validate settings without depending on a particular screenshot's size.
            _ = try CanvasRenderer.layout(sourceSize: CGSize(width: 1, height: 1), state: EditState(style: preset.style))
        }
    }
}
