import Foundation
import Testing
@testable import DockStateCore

/// Regression tests for the second review of the hardening branches.
@Suite struct ReviewFollowupTests {
    @Test func openingTheLidNextToIdenticalMonitorsDoesNotSwapThem() {
        // Clamshell desk: two identical monitors, no serial, same UUID.
        var a = Fixtures.display("A", uuid: "SAME", x: 0); a.serialNumber = 0
        var b = Fixtures.display("B", uuid: "SAME", x: 1920); b.serialNumber = 0
        let lid = Fixtures.display("MB", vendor: 0x610, model: 0xA050, builtin: true, x: -1728, y: 0, w: 1728, h: 1117)
        var a2 = a; a2.id = "C1"
        var b2 = b; b2.id = "C2"
        let m = DisplayMatcher.match(saved: [a, b], current: [lid, a2, b2])
        #expect(m.quality == .withExtraDisplays)
        #expect(m.mapping["A"]?.id == "C1")
        #expect(m.mapping["B"]?.id == "C2")
        #expect(!m.isAmbiguous)
    }

    @Test func wholeDeskBeatsAnAlwaysSubset() {
        let clamshell = Workspace(name: "Clamshell", displays: [Fixtures.lg, Fixtures.dell], windows: [], autoMode: .always)
        let home = Workspace(name: "Home Desk", displays: Fixtures.homeDisplays, windows: [], autoMode: .ask)
        let sidecar = Fixtures.display("SIDECAR", vendor: 0, model: 0, name: "Sidecar", x: 0, y: 1440, w: 1024, h: 768)
        let picked = WorkspaceRecognizer.recognized([clamshell, home], current: Fixtures.homeDisplays + [sidecar])
        #expect(picked?.workspace.name == "Home Desk")
    }

    @Test func undecodableNewerSchemaStaysReadOnlyAndInPlace() throws {
        let dir = Fixtures.tempDirectory()
        let url = dir.appendingPathComponent("w.json")
        let original = #"{"schemaVersion":99,"workspaces":[{"name":"Future","layout":{"v":2}}]}"#
        try Data(original.utf8).write(to: url)
        let result = WorkspaceStore(fileURL: url).load()
        #expect(result.isReadOnly)
        guard case .newerSchema(99, _) = result.issue else { Issue.record("expected newerSchema"); return }
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
    }

    @Test func ambiguousExcludedWindowStaysExcludedOnUpdate() {
        // Titles off, two same-size Terminal windows on the same display: exclusion must survive.
        let a = Scenario.live("com.apple.Terminal", nil, Frame(x: 20, y: 40, width: 800, height: 600), order: 0)
        let b = Scenario.live("com.apple.Terminal", nil, Frame(x: 900, y: 40, width: 800, height: 600), order: 1)
        var ws = WorkspaceCapture.capture(name: "x", displays: [Fixtures.lg], windows: [a, b], includeTitles: false)
        ws.windows[1].isExcluded = true
        var a2 = a, b2 = b
        a2.frame.origin(300, 300); a2.appOrder = 1
        b2.frame.origin(350, 350); b2.appOrder = 0
        let keep = ws.liveIDsOfExcludedWindows(in: [a2, b2], currentDisplays: [Fixtures.lg], runningBundleIDs: ["com.apple.Terminal"])
        #expect(!keep.isEmpty)
    }

    @Test func setupKeyIgnoresEnumerationOrderOfDuplicates() {
        let a = Fixtures.display("SAME", x: 0), b = Fixtures.display("SAME", x: 1920)
        #expect([a, b].uniquingIDs().setupKey == [b, a].uniquingIDs().setupKey)
    }

    @Test func importDoesNotTakeOverAutomation() {
        let mine = Workspace(name: "Home Desk", displays: Fixtures.homeDisplays, windows: [], autoMode: .ask)
        let theirs = Workspace(name: "Home Desk", displays: Fixtures.homeDisplays, windows: [], autoMode: .always,
                               lastRestoredAt: Date())
        let merged = WorkspaceTransfer.merge([theirs], into: [mine], includeTitles: true)
        #expect(merged[1].autoMode == .ask)
        #expect(merged[1].lastRestoredAt == nil)
        #expect(WorkspaceRecognizer.recognized(merged, current: Fixtures.homeDisplays)?.workspace.id == mine.id
                || merged[0].createdAt < merged[1].createdAt)
        // A workspace for a desk the user doesn't have yet keeps its setting.
        let office = Workspace(name: "Office", displays: [Fixtures.macbook, Fixtures.display("OFF", model: 9, x: 0)], windows: [], autoMode: .always)
        #expect(WorkspaceTransfer.merge([office], into: [mine], includeTitles: true)[1].autoMode == .always)
    }
}
