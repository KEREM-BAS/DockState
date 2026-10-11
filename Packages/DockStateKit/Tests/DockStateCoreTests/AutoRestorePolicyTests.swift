import Testing
@testable import DockStateCore

@Suite struct AutoRestorePolicyTests {
    func input(changed: Bool = true, mode: AutoMode? = .ask, moves: Int = 3, notify: Bool = true,
               suggested: Bool = false, workspaces: Bool = true, permission: Bool = true, onboarded: Bool = true) -> AutoRestorePolicy.Input {
        .init(setupChanged: changed, onboardingCompleted: onboarded, permissionGranted: permission, hasWorkspaces: workspaces,
              notifyOnConnect: notify, alreadySuggested: suggested, recognizedMode: mode, outOfPlace: moves)
    }

    @Test func sameSetupNeverActs() {
        // Wake, unlock, Dock moved: even "Always" does nothing.
        #expect(AutoRestorePolicy.action(for: input(changed: false, mode: .always)) == .none)
        #expect(AutoRestorePolicy.action(for: input(changed: false, mode: nil)) == .none)
    }

    @Test func modes() {
        #expect(AutoRestorePolicy.action(for: input(mode: .always)) == .restoreAutomatically)
        #expect(AutoRestorePolicy.action(for: input(mode: .ask)) == .notifyMatch(moves: 3))
        #expect(AutoRestorePolicy.action(for: input(mode: .ask, notify: false)) == .none)
        #expect(AutoRestorePolicy.action(for: input(mode: .never)) == .none)
    }

    @Test func nothingOutOfPlace() {
        #expect(AutoRestorePolicy.action(for: input(mode: .always, moves: 0)) == .none)
    }

    @Test func unknownSetupIsSuggestedOnce() {
        #expect(AutoRestorePolicy.action(for: input(mode: nil)) == .suggestSaving)
        #expect(AutoRestorePolicy.action(for: input(mode: nil, suggested: true)) == .none)
        #expect(AutoRestorePolicy.action(for: input(mode: nil, workspaces: false)) == .none)
        #expect(AutoRestorePolicy.action(for: input(mode: nil, notify: false)) == .none)
    }

    @Test func requiresPermissionAndOnboarding() {
        #expect(AutoRestorePolicy.action(for: input(mode: .always, permission: false)) == .none)
        #expect(AutoRestorePolicy.action(for: input(mode: .always, onboarded: false)) == .none)
    }
}

@Suite struct LatePlacementPolicyTests {
    @Test func needsConsent() {
        #expect(LatePlacementPolicy.allows(enabled: true, mode: .always, restoredOnSetup: nil, currentSetup: "A"))
        #expect(LatePlacementPolicy.allows(enabled: true, mode: .ask, restoredOnSetup: "A", currentSetup: "A"))
        // Restored on another desk (or never): no consent for this one.
        #expect(!LatePlacementPolicy.allows(enabled: true, mode: .ask, restoredOnSetup: "B", currentSetup: "A"))
        #expect(!LatePlacementPolicy.allows(enabled: true, mode: .ask, restoredOnSetup: nil, currentSetup: "A"))
        #expect(!LatePlacementPolicy.allows(enabled: true, mode: .never, restoredOnSetup: "A", currentSetup: "A"))
        #expect(!LatePlacementPolicy.allows(enabled: false, mode: .always, restoredOnSetup: "A", currentSetup: "A"))
    }
}
