import Foundation

/// On-disk envelope. `schemaVersion` lets future versions migrate old files and lets
/// old versions notice files written by newer ones.
struct StoreFile: Codable {
    var schemaVersion: Int
    var workspaces: [Workspace]
}

/// What happened while loading, so the UI can tell the user without losing data.
public enum StoreLoadIssue: Equatable, Sendable {
    /// The file could not be read; it was moved aside to `backupURL` and DockState started empty.
    case corrupted(backupURL: URL)
    /// The file came from a newer DockState; a copy was kept at `backupURL` before loading.
    case newerSchema(version: Int, backupURL: URL)
}

public struct StoreLoadResult: Sendable {
    public var workspaces: [Workspace]
    public var issue: StoreLoadIssue?
}

/// Persists workspaces as a single versioned JSON file, written atomically.
public struct WorkspaceStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/DockState/workspaces.json`
    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("DockState", isDirectory: true)
            .appendingPathComponent("workspaces.json")
    }

    public func load(now: Date = Date()) -> StoreLoadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return StoreLoadResult(workspaces: [], issue: nil) }

        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch {
            return StoreLoadResult(workspaces: [], issue: moveAside(suffix: "unreadable", now: now))
        }

        struct Header: Decodable { var schemaVersion: Int? }
        let decoder = Self.makeDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else {
            return StoreLoadResult(workspaces: [], issue: moveAside(suffix: "corrupt", now: now))
        }
        let version = header.schemaVersion ?? 0

        var issue: StoreLoadIssue?
        if version > DockStateCore.schemaVersion {
            // Keep the newer file intact somewhere safe before we ever overwrite it.
            let backup = backupURL(suffix: "schema\(version)", now: now)
            try? fm.copyItem(at: fileURL, to: backup)
            issue = .newerSchema(version: version, backupURL: backup)
        }

        do {
            let migrated = try Self.migrate(data: data, from: version)
            let file = try decoder.decode(StoreFile.self, from: migrated)
            return StoreLoadResult(workspaces: file.workspaces, issue: issue)
        } catch {
            return StoreLoadResult(workspaces: [], issue: moveAside(suffix: "corrupt", now: now))
        }
    }

    public func save(_ workspaces: [Workspace]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = StoreFile(schemaVersion: DockStateCore.schemaVersion, workspaces: workspaces)
        let data = try Self.makeEncoder().encode(file)
        try data.write(to: fileURL, options: [.atomic])
    }

    /// Upgrades older JSON to the current layout. Version 0 means "no version key";
    /// it never shipped, but the hook keeps future migrations in one place.
    static func migrate(data: Data, from version: Int) throws -> Data {
        guard version < 1 else { return data }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        object["schemaVersion"] = 1
        if object["workspaces"] == nil { object["workspaces"] = [] }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func backupURL(suffix: String, now: Date) -> URL {
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let name = fileURL.deletingPathExtension().lastPathComponent
        return fileURL.deletingLastPathComponent().appendingPathComponent("\(name).\(suffix)-\(stamp).json")
    }

    private func moveAside(suffix: String, now: Date) -> StoreLoadIssue {
        let backup = backupURL(suffix: suffix, now: now)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
        return .corrupted(backupURL: backup)
    }

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
