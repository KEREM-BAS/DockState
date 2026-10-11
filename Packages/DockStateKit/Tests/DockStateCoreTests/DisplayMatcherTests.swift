import Foundation
import Testing
@testable import DockStateCore

@Suite struct DisplayMatcherTests {
    let home = Fixtures.homeDisplays

    @Test func identicalSetupIsExact() {
        let m = DisplayMatcher.match(saved: home, current: home)
        #expect(m.quality == .exact)
        #expect(m.missing.isEmpty && m.extra.isEmpty)
        #expect(m.mapping["LG"]?.id == "LG")
    }

    @Test func differentPortChangesUUIDButSerialStillMatches() {
        var lg = Fixtures.lg
        lg.id = "LG-OTHER-PORT"; lg.uuid = "LG-OTHER-PORT"
        let m = DisplayMatcher.match(saved: home, current: [Fixtures.macbook, lg, Fixtures.dell])
        #expect(m.quality == .exact)
        #expect(m.mapping["LG"]?.id == "LG-OTHER-PORT")
    }

    @Test func rearrangedDisplaysAreSameDisplays() {
        var dell = Fixtures.dell
        dell.frame = Frame(x: -1920, y: -1080, width: 1920, height: 1080)
        let m = DisplayMatcher.match(saved: home, current: [Fixtures.macbook, Fixtures.lg, dell])
        #expect(m.quality == .sameDisplays)
        #expect(m.mapping["DELL"]?.id == "DELL")
    }

    @Test func resolutionChangeIsSameDisplays() {
        var lg = Fixtures.lg
        lg.frame = Frame(x: 0, y: 0, width: 1920, height: 1080); lg.pixelWidth = 3840; lg.pixelHeight = 2160
        let m = DisplayMatcher.match(saved: home, current: [Fixtures.macbook, lg, Fixtures.dell])
        #expect(m.quality == .sameDisplays)
    }

    @Test func laptopOnlyIsPartialForHomeDesk() {
        let m = DisplayMatcher.match(saved: home, current: [Fixtures.macbook])
        #expect(m.quality == .partial)
        #expect(Set(m.missing) == ["LG", "DELL"])
    }

    @Test func extraDisplayMakesLaptopWorkspacePartial() {
        let m = DisplayMatcher.match(saved: [Fixtures.macbook], current: home)
        #expect(m.quality == .partial)
        #expect(m.extra.count == 2)
    }

    @Test func differentSerialIsADifferentMonitor() {
        var otherLG = Fixtures.lg
        otherLG.serialNumber = 0x9999; otherLG.uuid = "X"; otherLG.id = "X"
        let m = DisplayMatcher.match(saved: home, current: [Fixtures.macbook, otherLG, Fixtures.dell])
        #expect(m.mapping["LG"] == nil)
        #expect(m.quality == .partial)
    }

    @Test func differentModelNeverMatches() {
        var office = Fixtures.dell
        office.modelID = 0xBEEF; office.uuid = "OFFICE"; office.id = "OFFICE"
        #expect(DisplayMatcher.pairScore(saved: Fixtures.dell, current: office) == nil)
    }

    @Test func identicalMonitorsWithoutSerialAreToldApartByPosition() {
        let left = Fixtures.display("A", x: 0, y: 0)
        let right = Fixtures.display("B", x: 1920, y: 0)
        // Reconnected through other ports: UUIDs changed, positions kept.
        var newLeft = left; newLeft.id = "P1"; newLeft.uuid = "P1"
        var newRight = right; newRight.id = "P2"; newRight.uuid = "P2"
        let m = DisplayMatcher.match(saved: [left, right], current: [newRight, newLeft])
        #expect(m.mapping["A"]?.id == "P1")
        #expect(m.mapping["B"]?.id == "P2")
        #expect(!m.isAmbiguous)
    }

    @Test func indistinguishableMonitorsAreFlaggedAmbiguous() {
        // Same model, no serial, no UUID, same position — nothing tells them apart.
        var a = Fixtures.display("A", x: 0); a.uuid = nil
        var b = Fixtures.display("B", x: 0); b.uuid = nil
        var c1 = a; c1.id = "C1"
        var c2 = a; c2.id = "C2"
        let m = DisplayMatcher.match(saved: [a, b], current: [c1, c2])
        #expect(m.isAmbiguous)
    }

    @Test func builtinNeverMatchesExternal() {
        #expect(DisplayMatcher.pairScore(saved: Fixtures.macbook, current: Fixtures.lg) == nil)
    }

    @Test func emptyInputs() {
        #expect(DisplayMatcher.match(saved: [], current: home).quality == .none)
        #expect(DisplayMatcher.match(saved: home, current: []).missing.count == 3)
    }
}

@Suite struct WorkspaceRecognizerTests {
    @Test func picksRecognizedWorkspaceOnly() {
        let homeWS = Workspace(name: "Home Desk", displays: Fixtures.homeDisplays, windows: [])
        let laptopWS = Workspace(name: "Laptop Only", displays: [Fixtures.macbook], windows: [])
        let atHome = WorkspaceRecognizer.recognized([laptopWS, homeWS], current: Fixtures.homeDisplays)
        #expect(atHome?.workspace.name == "Home Desk")
        let onTheRoad = WorkspaceRecognizer.recognized([laptopWS, homeWS], current: [Fixtures.macbook])
        #expect(onTheRoad?.workspace.name == "Laptop Only")
        let office = WorkspaceRecognizer.recognized([homeWS], current: [Fixtures.macbook, Fixtures.display("OFF", model: 1, x: 0)])
        #expect(office == nil)
    }

    @Test func prefersNewestOnTieRegardlessOfEdits() {
        // Editing (updatedAt) must not change which workspace wins; creation order does.
        let old = Workspace(name: "Old", displays: [Fixtures.macbook], windows: [],
                            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date())
        let new = Workspace(name: "New", displays: [Fixtures.macbook], windows: [],
                            createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100))
        #expect(WorkspaceRecognizer.recognized([old, new], current: [Fixtures.macbook])?.workspace.name == "New")
    }
}

@Suite struct SettleDebouncerTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func burstRunsActionOnce() async throws {
        let debouncer = SettleDebouncer(delay: .milliseconds(80))
        let counter = Counter()
        for _ in 0..<6 {
            await debouncer.signal { counter.increment() }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.count == 1)
    }

    @Test func cancelPreventsAction() async throws {
        let debouncer = SettleDebouncer(delay: .milliseconds(50))
        let counter = Counter()
        await debouncer.signal { counter.increment() }
        await debouncer.cancel()
        try await Task.sleep(for: .milliseconds(200))
        #expect(counter.count == 0)
    }
}
