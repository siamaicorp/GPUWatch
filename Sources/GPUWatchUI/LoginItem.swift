import Foundation
import ServiceManagement

/// Launch-at-login, opt-in only.
///
/// Uses `SMAppService.mainApp`, the API that matches this deployment target.
/// The older `LSSharedFileList` approach is deprecated and does not behave the
/// same on modern macOS. Registration is only ever attempted when the operator
/// turns the switch on; nothing here runs at startup.
enum LoginItem {
    enum Failure: Error, LocalizedError {
        case registrationFailed(String)

        var errorDescription: String? {
            switch self {
            case let .registrationFailed(detail):
                return "Could not change the login item: \(detail)"
            }
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        do {
            if enabled {
                // Registering an already-registered item throws; treat that as
                // success because the desired state is the current state.
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        } catch {
            throw Failure.registrationFailed(error.localizedDescription)
        }
    }
}
