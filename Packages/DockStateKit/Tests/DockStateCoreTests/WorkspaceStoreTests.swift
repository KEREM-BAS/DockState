import Foundation
import Testing
@testable import DockStateCore

@Suite struct WorkspaceStoreTests {
    func sampleWorkspace() -> Workspace {
        Workspace(
            name: "Home Desk", displays: Fixtures.homeDisplays,
            windows: [
                SavedWindow(
                    bundleID: "com.apple.Safari", appName: "Safari", title: "GitHub", role: "AXWindow",
                    subrole: "AXStandardWindow", displayID: "DELL",
                    frameInDisplay: Frame(x: 20, y: 30, width: 1200, height: 900), appOrder: 0)
            ])
    }

    @Test func missingFileLoadsEmpty() {
        let store = WorkspaceStore(fileURL: Fixtures.tempDirectory().appendingPathComponent("w.json"))
        let result = store.load()
        #expect(result.workspaces.isEmpty)
        #expect(result.issue == nil)
    }

    @Test func roundTrip() throws {
        let store = WorkspaceStore(fileURL: Fixtures.tempDirectory().appendingPathComponent("w.json"))
        let ws = sampleWorkspace()
        try store.save([ws])
        let loaded = store.load()
        #expect(loaded.issue == nil)
        #expect(loaded.workspaces.count == 1)
        #expect(loaded.workspaces[0].name == "Home Desk")
        #expect(loaded.workspaces[0].windows == ws.windows)
        #expect(loaded.workspaces[0].displays == ws.displays)
    }

    @Test func corruptFileIsMovedAsideNotDeleted() throws {
        let dir = Fixtures.tempDirectory()
        let url = dir.appendingPathComponent("w.json")
        try Data("{ not json".utf8).write(to: url)
        let result = WorkspaceStore(fileURL: url).load()
        #expect(result.workspaces.isEmpty)
        guard case .corrupted(let backup) = result.issue else { Issue.record("expected corrupted"); return }
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try String(contentsOf: backup, encoding: .utf8) == "{ not json")
    }

    @Test func structurallyInvalidFileIsTreatedAsCorrupt() throws {
        let url = Fixtures.tempDirectory().appendingPathComponent("w.json")
        try Data(#"{"schemaVersion":1,"workspaces":[{"name":42}]}"#.utf8).write(to: url)
        let result = WorkspaceStore(fileURL: url).load()
        guard case .corrupted = result.issue else { Issue.record("expected corrupted"); return }
    }

    @Test func newerSchemaIsBackedUpAndLoadedBestEffort() throws {
        let url = Fixtures.tempDirectory().appendingPathComponent("w.json")
        let store = WorkspaceStore(fileURL: url)
        try store.save([sampleWorkspace()])
        // Simulate a file from a future version with extra fields and an unknown auto mode.
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["schemaVersion"] = 99
        json["futureField"] = ["x": 1]
        var list = json["workspaces"] as! [[String: Any]]
        list[0]["autoMode"] = "smart"
        json["workspaces"] = list
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let result = store.load()
        #expect(result.workspaces.count == 1)
        #expect(result.workspaces[0].autoMode == .ask)
        guard case .newerSchema(99, let backup) = result.issue else { Issue.record("expected newerSchema"); return }
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func unversionedFileIsMigrated() throws {
        let url = Fixtures.tempDirectory().appendingPathComponent("w.json")
        try Data(#"{"workspaces":[{"name":"Old","displays":[]}]}"#.utf8).write(to: url)
        let result = WorkspaceStore(fileURL: url).load()
        #expect(result.issue == nil)
        #expect(result.workspaces.first?.name == "Old")
        #expect(result.workspaces.first?.windows.isEmpty == true)
    }

    @Test func strippingTitlesRemovesAllTitles() {
        let ws = sampleWorkspace().strippingTitles()
        #expect(ws.windows.allSatisfy { $0.title == nil })
    }
}
