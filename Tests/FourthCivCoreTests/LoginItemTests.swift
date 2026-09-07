import Foundation
import Testing
@testable import FourthCivCore

struct LoginItemTests {
    @MainActor private final class Service {
        var state: LoginItemState = .notRegistered
        var registrationState: LoginItemState = .enabled
        var registrations = 0
        var removals = 0
        var fail = false
        func controller(_ defaults: UserDefaults, available: Bool = true) -> LoginItemController {
            LoginItemController(available: available, defaults: defaults, readState: { self.state }, register: {
                self.registrations += 1
                if self.fail { throw CivError("Test registration failure") }
                self.state = self.registrationState
            }, unregister: {
                self.removals += 1
                if self.fail { throw CivError("Test removal failure") }
                self.state = .notRegistered
            })
        }
    }

    private func preferences() -> (String, UserDefaults) {
        let suite = "FourthCiv.LoginItemTests.\(UUID().uuidString)"
        return (suite, UserDefaults(suiteName: suite)!)
    }

    @Test @MainActor func firstLaunchRegistersOnceAndManualOptOutSurvivesRestart() {
        let (suite, defaults) = preferences(); defer { defaults.removePersistentDomain(forName: suite) }
        let service = Service(), controller = service.controller(defaults)
        controller.start(); controller.start()
        #expect(controller.state == .enabled && service.registrations == 1)
        controller.setEnabled(false)
        let restarted = service.controller(defaults); restarted.start()
        #expect(restarted.state == .notRegistered && service.registrations == 1 && service.removals == 1)
        restarted.setEnabled(true)
        #expect(restarted.state == .enabled && service.registrations == 2)
    }

    @Test @MainActor func systemChangesAndExistingApprovalRequirementsAreRespected() {
        for initial in [LoginItemState.enabled, .requiresApproval] {
            let (suite, defaults) = preferences(); defer { defaults.removePersistentDomain(forName: suite) }
            let service = Service(); service.state = initial
            let controller = service.controller(defaults); controller.start()
            #expect(service.registrations == 0 && controller.state == initial)
            service.state = .requiresApproval
            controller.refresh(); controller.start()
            #expect(controller.state == .requiresApproval && service.registrations == 0)
            service.state = .notRegistered
            service.controller(defaults).start()
            #expect(service.registrations == 0)
        }
    }

    @Test @MainActor func failuresReflectSystemStateAndCanBeRetriedExplicitly() {
        let (suite, defaults) = preferences(); defer { defaults.removePersistentDomain(forName: suite) }
        let service = Service(); service.fail = true
        let controller = service.controller(defaults); controller.start(); controller.start()
        #expect(controller.state == .notRegistered && controller.failure != nil && service.registrations == 1)
        service.fail = false; controller.setEnabled(true)
        #expect(controller.state == .enabled && controller.failure == nil)
        service.fail = true; controller.setEnabled(false)
        #expect(controller.state == .enabled && controller.failure != nil)
    }

    @Test @MainActor func unavailableSessionsDoNotRegisterOrConsumeTheDefault() {
        let (suite, defaults) = preferences(); defer { defaults.removePersistentDomain(forName: suite) }
        let service = Service(), preview = service.controller(defaults, available: false)
        preview.start(); preview.setEnabled(true); preview.setEnabled(false)
        #expect(service.registrations == 0 && service.removals == 0)
        service.controller(defaults).start()
        #expect(service.registrations == 1)
    }

    @Test @MainActor func firstLaunchAttemptsRegistrationWhenTheServiceIsNotFoundYet() {
        let (suite, defaults) = preferences(); defer { defaults.removePersistentDomain(forName: suite) }
        let service = Service(); service.state = .notFound
        let controller = service.controller(defaults); controller.start()
        #expect(service.registrations == 1 && controller.state == .enabled)
    }

    @Test @MainActor func successfulRegistrationCanStillRequireSystemApproval() {
        let (suite, defaults) = preferences(); defer { defaults.removePersistentDomain(forName: suite) }
        let service = Service(); service.registrationState = .requiresApproval
        let controller = service.controller(defaults); controller.start(); controller.start()
        #expect(controller.state == .requiresApproval && service.registrations == 1)
        controller.setEnabled(false)
        service.controller(defaults).start()
        #expect(service.state == .notRegistered && service.registrations == 1)
    }
}
