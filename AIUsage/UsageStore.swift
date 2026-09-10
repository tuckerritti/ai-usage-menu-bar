import AppKit
import SwiftUI

extension UsageMetric {
    var provider: UsageProvider {
        self == .codexWeekly ? .codex : .claude
    }

    var title: String {
        switch self {
        case .claudeSession: return "Session"
        case .claudeWeekly: return "Weekly · all models"
        case .claudeFable: return "Weekly · Fable"
        case .codexWeekly: return "Weekly"
        }
    }

    var accessibilityName: String {
        switch self {
        case .claudeSession: return "Claude session"
        case .claudeWeekly: return "Claude weekly, all models"
        case .claudeFable: return "Claude Fable weekly"
        case .codexWeekly: return "Codex weekly"
        }
    }
}

struct MetricState {
    var reading: UsageReading?
    var updatedAt: Date?
    var error: String?

    var percentage: String {
        reading.map { "\(Int($0.usedPercent.rounded()))%" } ?? "—"
    }

    var isStale: Bool {
        reading != nil && (error != nil || Date().timeIntervalSince(updatedAt ?? .distantPast) > 120)
    }

    var color: NSColor {
        guard let reading, !isStale else { return .secondaryLabelColor }
        switch reading.usedPercent {
        case ..<50: return .systemGreen
        case ..<80: return .systemOrange
        default: return .systemRed
        }
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var metrics: [UsageMetric: MetricState] = [:]
    @Published private(set) var refreshing: Set<UsageProvider> = []
    @Published private(set) var errors: [UsageProvider: String] = [:]
    @Published private(set) var lastAttempt: Date?
    private var requests: [UsageProvider: Task<Void, Never>] = [:]
    private var polling: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    init() {
        polling = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func state(_ metric: UsageMetric) -> MetricState {
        metrics[metric] ?? MetricState()
    }

    func refreshIfNeeded() {
        if Date().timeIntervalSince(lastAttempt ?? .distantPast) >= 60 { refresh() }
    }

    func refresh() {
        for provider in UsageProvider.allCases where requests[provider] == nil {
            refreshing.insert(provider)
            lastAttempt = Date()
            requests[provider] = Task { [weak self] in
                let result = await UsageClient.fetch(provider)
                guard let self, !Task.isCancelled else { return }
                let fetchedAt = Date()
                for metric in UsageMetric.allCases where metric.provider == provider {
                    if let reading = result.readings[metric] {
                        self.metrics[metric] = MetricState(reading: reading, updatedAt: fetchedAt)
                    } else {
                        var previous = self.state(metric)
                        previous.error = result.error ?? "This allowance was not reported by the CLI."
                        self.metrics[metric] = previous
                    }
                }
                self.errors[provider] = result.error
                self.refreshing.remove(provider)
                self.requests[provider] = nil
            }
        }
    }

    func stop() {
        polling?.cancel()
        requests.values.forEach { $0.cancel() }
        UsageClient.cancelAll()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    var accessibilityLabel: String {
        [.claudeSession, .codexWeekly].map { (metric: UsageMetric) in
            let value = state(metric)
            let description = value.reading == nil ? "Unavailable" : "\(value.percentage) used\(value.isStale ? ", stale" : "")"
            return "\(metric.accessibilityName): \(description)"
        }.joined(separator: "; ")
    }
}
