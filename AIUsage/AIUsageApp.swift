import AppKit
import Combine
import SwiftUI

@main
enum AIUsageApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = UsageStore()
    private let settings = StartupSettings()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var appearanceObservation: NSKeyValueObservation?
    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.updateStatusItem() }
            }
        }

        let content = NSHostingController(rootView: UsagePanel(store: store, settings: settings))
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        popover.behavior = .transient
        popover.delegate = self

        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &subscriptions)
        updateStatusItem()
    }

    @objc private func statusItemClicked(_ button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            button.highlight(true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem?.button?.highlight(false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        button.image = menuBarImage(appearance: button.effectiveAppearance)
        button.setAccessibilityLabel(store.accessibilityLabel)
        button.toolTip = store.accessibilityLabel
    }

    private func menuBarImage(appearance: NSAppearance) -> NSImage {
        let values: [(String, MetricState)] = [
            ("ClaudeLogo", store.state(.claudeSession)),
            ("ChatGPTLogo", store.state(.codexWeekly))
        ]
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let textWidths = values.map {
            ($0.1.percentage as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        }
        let logoToTextGap: CGFloat = 3
        let width = textWidths.reduce((14 + logoToTextGap) * 2 + 6, +)
        let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance {
                var x: CGFloat = 0
                for (index, value) in values.enumerated() {
                    if let logo = NSImage(named: value.0) {
                        let rect = NSRect(x: x, y: 2, width: 14, height: 14)
                        NSGraphicsContext.saveGraphicsState()
                        logo.draw(in: rect)
                        NSColor.labelColor.setFill()
                        rect.fill(using: .sourceAtop)
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: value.1.color
                    ]
                    (value.1.percentage as NSString).draw(at: NSPoint(x: x + 14 + logoToTextGap, y: 1.5), withAttributes: attributes)
                    if value.1.isStale {
                        NSColor.systemOrange.setFill()
                        NSBezierPath(ovalIn: NSRect(x: x + 10, y: 0, width: 4, height: 4)).fill()
                    }
                    x += 14 + logoToTextGap + textWidths[index] + 6
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

private struct UsagePanel: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: StartupSettings
    @State private var isQuitHovered = false
    @State private var isShowingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI Usage Remaining").font(.headline)

            providerSection(.claude, title: "Claude", logo: "ClaudeLogo")
            Divider()
            providerSection(.codex, title: "Codex", logo: "ChatGPTLogo")
            Divider()

            if isShowingSettings {
                SettingsView(settings: settings)
                Divider()
            }

            HStack(spacing: 12) {
                if !store.refreshing.isEmpty {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing usage")
                    Text("Updating…").font(.caption).foregroundStyle(.secondary)
                } else if let date = store.lastAttempt {
                    Text("Checked \(date, style: .time)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    isShowingSettings.toggle()
                    if isShowingSettings { settings.refresh() }
                } label: {
                    Image(systemName: isShowingSettings ? "gearshape.fill" : "gearshape")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Settings")
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.primary.opacity(isQuitHovered ? 0.08 : 0))
                        .allowsHitTesting(false)
                }
                .onHover { isQuitHovered = $0 }
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    private func providerSection(_ provider: UsageProvider, title: String, logo: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(logo).renderingMode(.template).resizable().scaledToFit().frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            ForEach(UsageMetric.allCases.filter { $0.provider == provider }, id: \.self) { metric in
                UsageRow(metric: metric, state: store.state(metric), loading: store.refreshing.contains(provider))
            }
            if let error = store.errors[provider] {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct UsageRow: View {
    let metric: UsageMetric
    let state: MetricState
    let loading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(metric.title).font(.system(size: 12))
                Spacer()
                if state.isStale {
                    Text("Stale").font(.caption2).foregroundStyle(.secondary)
                }
                Text(state.percentage)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color(nsColor: state.color))
            }
            ProgressView(value: state.reading?.remainingPercent ?? 0, total: 100)
                .tint(Color(nsColor: state.color))
                .opacity(state.reading == nil ? 0.3 : 1)
                .accessibilityHidden(true)
            if let reset = state.reading?.resetDescription {
                Text("Resets \(reset)").font(.caption2).foregroundStyle(.secondary)
            } else if state.reading == nil {
                Text(loading ? "Reading usage…" : "Unavailable")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.accessibilityName)
        .accessibilityValue(state.reading == nil ? "Unavailable" : "\(state.percentage) remaining\(state.isStale ? ", stale" : ""). \(state.reading?.resetDescription ?? "")")
    }
}
