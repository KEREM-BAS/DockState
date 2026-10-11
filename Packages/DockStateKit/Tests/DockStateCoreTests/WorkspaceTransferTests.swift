import Foundation
import Testing
@testable import DockStateCore

@Suite struct WorkspaceTransferTests {
    func sample(_ name: String = "Home Desk") -> Workspace {
        Scenario.save(Scenario.homeDeskWindows()).renamed(name)
    }

    @Test func roundTrip() throws {
        let data = try WorkspaceTransfer.export([sample()], includeTitles: true)
        let back = try WorkspaceTransfer.decode(data)
        #expect(back.count == 1)
        #expect(back[0].windows.count == 5)
        #expect(back[0].windows.contains { $0.title != nil })
    }

    @Test func exportWithoutTitles() throws {
        let data = try WorkspaceTransfer.export([sample()], includeTitles: false)
        #expect(try WorkspaceTransfer.decode(data)[0].windows.allSatisfy { $0.title == nil })
    }

    @Test func importNeverOverwrites() throws {
        let existing = [sample("Home Desk"), sample("Office")]
        let imported = [sample("Home Desk"), sample("Home Desk"), sample("Studio")]
        let merged = WorkspaceTransfer.merge(imported, into: existing, includeTitles: true)
        #expect(merged.map(\.name) == ["Home Desk", "Office", "Home Desk (2)", "Home Desk (3)", "Studio"])
        #expect(Set(merged.map(\.id)).count == merged.count)
        #expect(merged[0] == existing[0])
    }

    @Test func importStripsTitlesWhenTitlesAreOff() {
        let merged = WorkspaceTransfer.merge([sample()], into: [], includeTitles: false)
        #expect(merged[0].windows.allSatisfy { $0.title == nil })
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: WorkspaceTransfer.ImportError.notAWorkspaceFile) { try WorkspaceTransfer.decode(Data("hello".utf8)) }
        #expect(throws: WorkspaceTransfer.ImportError.notAWorkspaceFile) {
            try WorkspaceTransfer.decode(Data(#"{"schemaVersion":1,"workspaces":[{"name":1}]}"#.utf8))
        }
        #expect(throws: WorkspaceTransfer.ImportError.empty) {
            try WorkspaceTransfer.decode(Data(#"{"schemaVersion":1,"workspaces":[]}"#.utf8))
        }
    }
}

extension Workspace {
    func renamed(_ name: String) -> Workspace { var w = self; w.name = name; return w }
}
