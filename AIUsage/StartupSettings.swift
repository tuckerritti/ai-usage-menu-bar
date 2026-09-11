import ServiceManagement
import SwiftUI

@MainActor
final class StartupSettings: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var errorMessage: String?

    var isEnabled: Bool { status == .enabled }

    func refresh() {
        status = SMAppService.mainApp.status
        errorMessage = nil
    }

    func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        status = service.status
        errorMessage = nil
        defer { status = service.status }
        guard enabled != isEnabled else { return }

        if enabled && status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = "Couldn’t change launch on startup. \(error.localizedDescription)"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: StartupSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Launch on startup", isOn: Binding(
                get: { settings.isEnabled },
                set: { settings.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .accessibilityHint("Start AI Usage automatically when you log in.")

            if settings.status == .requiresApproval {
                Text("Allow AI Usage in System Settings → General → Login Items to launch automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }

            if let message = settings.errorMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
