import Foundation

// Same-module name lookup shadows the imported framework type, so these checks
// run the real settings model without reading or changing macOS login items.
@MainActor
final class SMAppService {
    enum Status { case notRegistered, enabled, requiresApproval, notFound }
    static let mainApp = SMAppService()
    var status = Status.notFound
    var registrationStatus = Status.enabled
    var unregistrationStatus = Status.notRegistered
    var error: Error?
    private(set) var registrations = 0
    private(set) var unregistrations = 0
    private(set) var settingsOpened = 0

    func register() throws {
        registrations += 1
        status = registrationStatus
        if let error { throw error }
    }

    func unregister() throws {
        unregistrations += 1
        status = unregistrationStatus
        if let error { throw error }
    }

    static func openSystemSettingsLoginItems() { mainApp.settingsOpened += 1 }
}

@main
struct StartupSettingsChecks {
    @MainActor
    static func main() {
        let suite = "StartupSettingsChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let layoutSettings = StartupSettings(defaults: defaults)
        assert(!layoutSettings.stackedMenuBar, "Basic must be the default layout")
        layoutSettings.stackedMenuBar = true
        assert(StartupSettings(defaults: defaults).stackedMenuBar, "Stacked must survive relaunch")
        layoutSettings.refresh()
        assert(layoutSettings.stackedMenuBar, "Refreshing login status must preserve the layout")
        layoutSettings.stackedMenuBar = false
        assert(!StartupSettings(defaults: defaults).stackedMenuBar, "Basic must survive relaunch")

        let service = SMAppService.mainApp
        let settings = StartupSettings()
        assert(settings.status == .notFound && !settings.isEnabled)
        settings.refresh()
        settings.setEnabled(false)
        assert(service.registrations == 0 && service.unregistrations == 0)

        settings.setEnabled(true)
        assert(settings.isEnabled && settings.errorMessage == nil)
        settings.setEnabled(true)
        assert(service.registrations == 1, "Already enabled must not register again")
        settings.setEnabled(false)
        assert(!settings.isEnabled && settings.errorMessage == nil)
        assert(service.unregistrations == 1)

        let error = NSError(domain: "StartupSettingsChecks", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Test failure"])
        service.error = error
        service.registrationStatus = .notRegistered
        settings.setEnabled(true)
        assert(!settings.isEnabled && settings.errorMessage?.contains("Test failure") == true)

        // An operation may change system state before throwing; display the
        // actual resulting status rather than blindly reverting the switch.
        service.registrationStatus = .enabled
        settings.setEnabled(true)
        assert(settings.isEnabled && settings.errorMessage?.contains("Test failure") == true)
        service.unregistrationStatus = .enabled
        settings.setEnabled(false)
        assert(settings.isEnabled && settings.errorMessage?.contains("Test failure") == true)
        service.unregistrationStatus = .notRegistered
        settings.setEnabled(false)
        assert(!settings.isEnabled && settings.errorMessage?.contains("Test failure") == true)
        service.error = nil

        let registrations = service.registrations
        let unregistrations = service.unregistrations
        service.status = .requiresApproval
        settings.refresh()
        assert(!settings.isEnabled && settings.errorMessage == nil)
        settings.setEnabled(true)
        assert(!settings.isEnabled && settings.status == .requiresApproval)
        assert(service.settingsOpened == 1 && service.registrations == registrations)

        service.status = .enabled
        settings.refresh()
        assert(settings.isEnabled)
        assert(StartupSettings().isEnabled, "Initialization must read existing system state")
        service.status = .notFound
        settings.refresh()
        assert(!settings.isEnabled)
        service.status = .notRegistered
        settings.refresh()
        assert(!settings.isEnabled)
        assert(service.registrations == registrations && service.unregistrations == unregistrations,
               "Initialization and external status refreshes must not change login items")
        print("Menu bar layout persistence and startup settings checks passed.")
    }
}
