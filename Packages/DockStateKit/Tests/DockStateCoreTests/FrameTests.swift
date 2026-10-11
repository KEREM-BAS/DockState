import Testing
@testable import DockStateCore

@Suite struct FrameTests {
    @Test func clampingShrinksAndMovesInside() {
        let bounds = Frame(x: 0, y: 25, width: 1000, height: 700)
        let f = Frame(x: 900, y: -50, width: 1200, height: 300).clamped(into: bounds)
        #expect(f == Frame(x: 0, y: 25, width: 1000, height: 300))
    }

    @Test func approximateEquality() {
        let a = Frame(x: 10, y: 10, width: 100, height: 100)
        #expect(a.isApproximatelyEqual(to: Frame(x: 11.5, y: 9, width: 101, height: 100)))
        #expect(!a.isApproximatelyEqual(to: Frame(x: 14, y: 10, width: 100, height: 100)))
    }

    @Test func displayContainingUsesCentreThenOverlap() {
        let displays = Fixtures.homeDisplays
        #expect(displays.display(containing: Frame(x: 100, y: 100, width: 400, height: 300))?.id == "LG")
        // Centre is in a gap between displays but the window overlaps the Dell.
        let straddling = Frame(x: 2500, y: 1200, width: 400, height: 300)
        #expect(displays.display(containing: straddling)?.id == "DELL")
        #expect(displays.display(containing: Frame(x: 99999, y: 0, width: 10, height: 10)) == nil)
    }
}
