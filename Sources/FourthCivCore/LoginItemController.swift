import Combine
import Foundation

public enum LoginItemState {
    case notRegistered, enabled, requiresApproval, notFound
}

/// The operating system owns the current state; remember only whether the default was attempted.
@MainActor public final class LoginItemController: ObservableObject {
    @Published public private(set) var state: LoginItemState = .notRegistered
    @Published public private(set) var failure: String?
    public let available: Bool
    private let defaults: UserDefaults
    private let readState: () -> LoginItemState
    private let register: () throws -> Void
    private let unregister: () throws -> Void
    private let preference = "FourthCivLoginItemInitialized"

    public init(available: Bool, defaults: UserDefaults = .standard,
                readState: @escaping () -> LoginItemState,
                register: @escaping () throws -> Void, unregister: @escaping () throws -> Void) {
        self.available = available; self.defaults = defaults
        self.readState = readState; self.register = register; self.unregister = unregister
    }

    public func start() {
        guard available else { return }
        refresh()
        guard !defaults.bool(forKey: preference) else { return }
        // Never reregister on every launch or undo a choice made in System Settings.
        defaults.set(true, forKey: preference)
        if state == .notRegistered || state == .notFound { setEnabled(true) }
    }

    public func refresh() {
        guard available else { return }
        let current = readState()
        if current != state { failure = nil }
        state = current
    }

    public func setEnabled(_ enabled: Bool) {
        guard available else { return }
        defaults.set(true, forKey: preference)
        failure = nil
        refresh()
        do {
            if enabled {
                if state == .notRegistered || state == .notFound { try register() }
            } else if state == .enabled || state == .requiresApproval {
                try unregister()
            }
        } catch { failure = error.localizedDescription }
        refresh()
    }
}
