import Foundation

/// What DockState does after the displays settled. Pure, so the rules are unit-tested.
public enum SettleAction: Equatable, Sendable {
    case none
    /// Suggest saving an unknown setup (once per setup).
    case suggestSaving
    /// Notify that the recognised workspace has windows out of place.
    case notifyMatch(moves: Int)
    /// Restore right away ("Always restore" workspaces).
    case restoreAutomatically
}

public enum AutoRestorePolicy {
    public struct Input: Sendable {
        /// The display setup differs from the one DockState last reacted to.
        public var setupChanged: Bool
        public var onboardingCompleted: Bool
        public var permissionGranted: Bool
        public var hasWorkspaces: Bool
        public var notifyOnConnect: Bool
        /// This unknown setup was already suggested for saving.
        public var alreadySuggested: Bool
        /// Auto mode of the recognised workspace, nil when the setup is unknown.
        public var recognizedMode: AutoMode?
        /// Windows of the recognised workspace that are out of place.
        public var outOfPlace: Int

        public init(setupChanged: Bool, onboardingCompleted: Bool, permissionGranted: Bool, hasWorkspaces: Bool,
                    notifyOnConnect: Bool, alreadySuggested: Bool, recognizedMode: AutoMode?, outOfPlace: Int) {
            self.setupChanged = setupChanged
            self.onboardingCompleted = onboardingCompleted
            self.permissionGranted = permissionGranted
            self.hasWorkspaces = hasWorkspaces
            self.notifyOnConnect = notifyOnConnect
            self.alreadySuggested = alreadySuggested
            self.recognizedMode = recognizedMode
            self.outOfPlace = outOfPlace
        }
    }

    public static func action(for input: Input) -> SettleAction {
        // Same desk after wake, unlock or a Dock change: never act.
        guard input.setupChanged, input.onboardingCompleted, input.permissionGranted else { return .none }
        guard let mode = input.recognizedMode else {
            return input.notifyOnConnect && input.hasWorkspaces && !input.alreadySuggested ? .suggestSaving : .none
        }
        guard input.outOfPlace > 0 else { return .none }
        switch mode {
        case .always: return .restoreAutomatically
        case .ask: return input.notifyOnConnect ? .notifyMatch(moves: input.outOfPlace) : .none
        case .never: return .none
        }
    }
}
