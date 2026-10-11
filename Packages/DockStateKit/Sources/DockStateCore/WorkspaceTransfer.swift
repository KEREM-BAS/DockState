import Foundation

/// Export and import of workspaces as a JSON file (backup, moving to another Mac).
/// The format is the same envelope as the on-disk store.
public enum WorkspaceTransfer {
    public enum ImportError: Error, Equatable {
        case notAWorkspaceFile
        case empty
    }

    public static func export(_ workspaces: [Workspace], includeTitles: Bool) throws -> Data {
        try WorkspaceStore.encode(includeTitles ? workspaces : workspaces.map { $0.strippingTitles() })
    }

    /// Reads an exported (or store) file. Files from newer versions are read best-effort.
    public static func decode(_ data: Data) throws -> [Workspace] {
        struct Header: Decodable { var schemaVersion: Int? }
        let decoder = WorkspaceStore.makeDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else { throw ImportError.notAWorkspaceFile }
        guard let migrated = try? WorkspaceStore.migrate(data: data, from: header.schemaVersion ?? 0),
              let file = try? decoder.decode(StoreFile.self, from: migrated) else { throw ImportError.notAWorkspaceFile }
        guard !file.workspaces.isEmpty else { throw ImportError.empty }
        return file.workspaces
    }

    /// Adds imported workspaces next to the existing ones. Imports never overwrite:
    /// they get new identities, and a name that's taken becomes "Name (2)".
    public static func merge(_ imported: [Workspace], into existing: [Workspace], includeTitles: Bool) -> [Workspace] {
        var result = existing
        var taken = Set(existing.map { $0.name.lowercased() })
        for var ws in imported {
            ws.id = UUID()
            // A restore on another Mac says nothing about this one, and an imported copy must
            // not take over automatic restores from a workspace the user already has here.
            ws.lastRestoredAt = nil
            if ws.autoMode == .always,
               existing.contains(where: { DisplayMatcher.match(saved: ws.displays, current: $0.displays).quality.isRecognized }) {
                ws.autoMode = .ask
            }
            ws.windows = ws.windows.map { var w = $0; w.id = UUID(); return w }
            if !includeTitles { ws = ws.strippingTitles() }
            var name = ws.name
            var n = 2
            while taken.contains(name.lowercased()) {
                name = "\(ws.name) (\(n))"
                n += 1
            }
            ws.name = name
            taken.insert(name.lowercased())
            result.append(ws)
        }
        return result
    }
}
