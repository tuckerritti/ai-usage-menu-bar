import AppKit
import SwiftUI

extension UsageReading {
    var remainingPercent: Double { 100 - usedPercent }
}

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
        reading.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "—"
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
    @Published private(set) var errors: [UsageProvider: String] = [:]
    @Published private(set) var lastAttempt: Date?
    @Published private var requests: [UUID: (provider: UsageProvider, task: Task<Void, Never>)] = [:]
    private var generation = 0
    private var polling: Task<Void, Never>?
    private let shellPath: Task<Result<String, ShellPathError>, Never>
    private var wakeObserver: NSObjectProtocol?
    private var windowObserver: NSObjectProtocol?

    var refreshing: Set<UsageProvider> { Set(requests.values.map(\.provider)) }

    init(shellPath: Task<Result<String, ShellPathError>, Never> = Task { await ShellPath.load() }) {
        self.shellPath = shellPath
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
        // The dropdown is our only window; SwiftUI can cache it between openings.
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func state(_ metric: UsageMetric) -> MetricState {
        metrics[metric] ?? MetricState()
    }

    func refresh() {
        generation += 1
        let generation = generation
        lastAttempt = Date()
        for provider in UsageProvider.allCases {
            let id = UUID()
            let task = Task { [weak self, shellPath] in
                let path = await shellPath.value
                guard !Task.isCancelled else {
                    self?.requests[id] = nil
                    return
                }
                let result: UsageFetchResult
                switch path {
                case .success(let path):
                    result = await UsageClient.fetch(provider, path: path)
                case .failure(let error):
                    result = UsageFetchResult(readings: [:], error: error.localizedDescription)
                }
                guard let self else { return }
                defer { self.requests[id] = nil }
                guard !Task.isCancelled, generation == self.generation else { return }
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
            }
            requests[id] = (provider, task)
        }
    }

    func stop() {
        shellPath.cancel()
        polling?.cancel()
        generation += 1
        requests.values.forEach { $0.task.cancel() }
        requests.removeAll()
        UsageClient.cancelAll()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }

    var accessibilityLabel: String {
        [.claudeSession, .codexWeekly].map { (metric: UsageMetric) in
            let value = state(metric)
            let description = value.reading == nil ? "Unavailable" : "\(value.percentage) remaining\(value.isStale ? ", stale" : "")"
            return "\(metric.accessibilityName): \(description)"
        }.joined(separator: "; ")
    }
}
