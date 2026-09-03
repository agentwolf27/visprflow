import Observation

/// Observable state shared by the menu bar content and the setup window.
@MainActor
@Observable
final class AppState {
    var permissions = PermissionStatus()

    @ObservationIgnored
    var onShowSetup: (@MainActor () -> Void)?

    func refreshPermissions() {
        let latest = PermissionsService.current()
        if latest != permissions {
            Log.permissions.info("Permissions changed: \(latest.description, privacy: .public)")
            permissions = latest
        }
    }

    func showSetup() {
        onShowSetup?()
    }
}
