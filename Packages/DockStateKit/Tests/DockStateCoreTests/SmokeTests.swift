import Testing
@testable import DockStateCore

@Test func schemaVersionIsPositive() {
    #expect(DockStateCore.schemaVersion > 0)
}
