import Foundation

/// On-disk envelope. `schemaVersion` lets future versions migrate old files and lets
/// old versions notice files written by newer ones.
struct StoreFile: Codable {
    var schemaVersion: Int
    var workspaces: [Workspace]
}

/// What happened while loading, so the UI can tell the user without losing data.
public enum StoreLoadIssue: Equatable, Sendable {
    /// The file could not be read. It was moved aside to `backupURL` and DockState started
    /// empty. `backupURL` is nil when even that failed — the store is then read-only so the
    /// damaged file is never overwritten.
    case corrupted(backupURL: URL?)
    /// The file came from a newer DockState. A copy was kept at `backupURL` (nil if copying
    /// failed). It was loaded best-effort and is read-only until the user agrees to convert it.
    case newerSchema(version: Int, backupURL: URL?)
}

public struct StoreLoadResult: Sendable {
    public var workspaces: [Workspace]
    public var issue: StoreLoadIssue?
    /// Saving would destroy data DockState doesn't understand or couldn't back up.
    /// The app must ask the user before calling `save`.
    public var isReadOnly: Bool

    public init(workspaces: [Workspace], issue: StoreLoadIssue?, isReadOnly: Bool = false) {
        self.workspaces = workspaces
        self.issue = issue
        self.isReadOnly = isReadOnly
    }
}

/// Persists workspaces as a single versioned JSON file, written atomically.
public struct WorkspaceStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/<folder>/workspaces.json` (`DockState` for releases).
    public static func defaultURL(folder: String = "DockState") throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("workspaces.json")
    }

    public func load(now: Date = Date()) -> StoreLoadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return StoreLoadResult(workspaces: [], issue: nil) }

        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch {
            return corrupted(suffix: "unreadable", now: now)
        }

        struct Header: Decodable { var schemaVersion: Int? }
        let decoder = Self.makeDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else {
            return corrupted(suffix: "corrupt", now: now)
        }
        let version = header.schemaVersion ?? 0

        if version > DockStateCore.schemaVersion {
            // Written by a newer DockState: keep the original safe (once per content), load
            // what this version understands, and never overwrite or move it unless the user
            // explicitly converts — even when nothing can be decoded.
            let backup = backupOnce(data: data, suffix: "schema\(version)", now: now)
            let workspaces = (try? decoder.decode(StoreFile.self, from: data))?.workspaces ?? []
            return StoreLoadResult(workspaces: workspaces, issue: .newerSchema(version: version, backupURL: backup), isReadOnly: true)
        }

        do {
            let migrated = try Self.migrate(data: data, from: version)
            let file = try decoder.decode(StoreFile.self, from: migrated)
            return StoreLoadResult(workspaces: file.workspaces, issue: nil)
        } catch {
            return corrupted(suffix: "corrupt", now: now)
        }
    }

    public func save(_ workspaces: [Workspace]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try Self.encode(workspaces)
        try data.write(to: fileURL, options: [.atomic])
    }

    /// The JSON written to disk (also used for export).
    public static func encode(_ workspaces: [Workspace]) throws -> Data {
        try makeEncoder().encode(StoreFile(schemaVersion: DockStateCore.schemaVersion, workspaces: workspaces))
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
        var url = fileURL.deletingLastPathComponent().appendingPathComponent("\(name).\(suffix)-\(stamp).json")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = fileURL.deletingLastPathComponent().appendingPathComponent("\(name).\(suffix)-\(stamp)-\(n).json")
            n += 1
        }
        return url
    }

    /// Copies `data` aside unless an identical backup with the same suffix already exists.
    private func backupOnce(data: Data, suffix: String, now: Date) -> URL? {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        let prefix = fileURL.deletingPathExtension().lastPathComponent + "." + suffix + "-"
        if let existing = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in existing where url.lastPathComponent.hasPrefix(prefix) {
                if let other = try? Data(contentsOf: url), other == data { return url }
            }
        }
        let backup = backupURL(suffix: suffix, now: now)
        do {
            try data.write(to: backup, options: [.atomic])
            return backup
        } catch {
            return nil
        }
    }

    /// Moves the unreadable file aside (copy as a fallback). If neither works, the store
    /// stays read-only so the file is not overwritten.
    private func corrupted(suffix: String, now: Date) -> StoreLoadResult {
        let fm = FileManager.default
        let backup = backupURL(suffix: suffix, now: now)
        if (try? fm.moveItem(at: fileURL, to: backup)) != nil {
            return StoreLoadResult(workspaces: [], issue: .corrupted(backupURL: backup))
        }
        if (try? fm.copyItem(at: fileURL, to: backup)) != nil {
            return StoreLoadResult(workspaces: [], issue: .corrupted(backupURL: backup))
        }
        return StoreLoadResult(workspaces: [], issue: .corrupted(backupURL: nil), isReadOnly: true)
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
