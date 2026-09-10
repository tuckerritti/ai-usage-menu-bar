import AppKit
import SwiftUI

@main
struct AIUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(store: store)
                .onAppear { store.refreshIfNeeded() }
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        UsageClient.cancelAll()
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: image)
            .renderingMode(.original)
            .accessibilityLabel(store.accessibilityLabel)
            .help(store.accessibilityLabel)
    }

    private var image: NSImage {
        let values: [(String, MetricState)] = [
            ("ClaudeLogo", store.state(.claudeSession)),
            ("ChatGPTLogo", store.state(.codexWeekly))
        ]
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!
        let image = NSImage(size: NSSize(width: 118, height: 18), flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance {
                for (index, value) in values.enumerated() {
                    let x = CGFloat(index) * 66
                    if let logo = NSImage(named: value.0) {
                        let rect = NSRect(x: x, y: 2, width: 14, height: 14)
                        NSGraphicsContext.saveGraphicsState()
                        logo.draw(in: rect)
                        NSColor.labelColor.setFill()
                        rect.fill(using: .sourceAtop)
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                        .foregroundColor: value.1.color
                    ]
                    (value.1.percentage as NSString).draw(at: NSPoint(x: x + 18, y: 1.5), withAttributes: attributes)
                    if value.1.isStale {
                        NSColor.systemOrange.setFill()
                        NSBezierPath(ovalIn: NSRect(x: x + 11, y: 0, width: 4, height: 4)).fill()
                    }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("AI Usage").font(.headline)
                Spacer()
                Text("USED").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }

            providerSection(.claude, title: "Claude", logo: "ClaudeLogo")
            Divider()
            providerSection(.codex, title: "Codex", logo: "ChatGPTLogo")
            Divider()

            HStack(spacing: 12) {
                if !store.refreshing.isEmpty {
                    ProgressView().controlSize(.small)
                    Text("Updating…").font(.caption).foregroundStyle(.secondary)
                } else if let date = store.lastAttempt {
                    Text("Checked \(date, style: .time)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh usage")
                .accessibilityLabel("Refresh usage")
                .keyboardShortcut("r")
                .disabled(!store.refreshing.isEmpty)

                Button("Quit") {
                    store.stop()
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
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
            ProgressView(value: state.reading?.usedPercent ?? 0, total: 100)
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
        .accessibilityValue(state.reading == nil ? "Unavailable" : "\(state.percentage) used\(state.isStale ? ", stale" : ""). \(state.reading?.resetDescription ?? "")")
    }
}
