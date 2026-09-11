import Foundation
import AppKit

@main
struct UsageChecks {
    static func main() async {
        let claude = """
        Current session: 12% used · resets Sep 10 at 9:29pm (America/New_York)
        Current week (all models): 19% used · resets Sep 12 at 4:59am (America/New_York)
        Current week (Fable): 34% used · resets Sep 12 at 4:59am (America/New_York)
        """
        let parsedClaude = UsageClient.parseClaude(claude)
        assert(parsedClaude.error == nil)
        assert(parsedClaude.readings[.claudeSession]?.usedPercent == 12)
        assert(parsedClaude.readings[.claudeWeekly]?.usedPercent == 19)
        assert(parsedClaude.readings[.claudeFable]?.usedPercent == 34)
        assert(parsedClaude.readings[.claudeSession]?.resetDescription == "Sep 10 at 9:29pm (America/New_York)")
        let partial = UsageClient.parseClaude("Current session: 0% used\nPer-model breakdown unavailable (rate limited)")
        assert(partial.readings[.claudeSession]?.usedPercent == 0)
        assert(partial.readings[.claudeFable] == nil && partial.error != nil)
        assert(UsageClient.parseClaude("Current session: 101% used").readings.isEmpty)
        assert(UsageClient.parseClaude("Current session: -1% used").readings.isEmpty)
        assert(UsageClient.parseClaude(claude.replacingOccurrences(of: "(Fable)", with: "(Fable 5.1)")).readings[.claudeFable]?.usedPercent == 34)

        let codex = """
        /status
        ╭────────────────────────────────────────────────────────────────╮
        │  Weekly limit: [████░░░░] 37% left (resets 08:59 on 17 Sep)     │
        │  Credits: 123 credits                                         │
        │  GPT-5.3-Codex-Spark limit:                                    │
        │  Weekly limit: [████████] 99% left (resets 09:00 on 18 Sep)     │
        ╰────────────────────────────────────────────────────────────────╯
        """
        let parsedCodex = UsageClient.parseCodex(codex)
        assert(parsedCodex.error == nil)
        assert(parsedCodex.readings[.codexWeekly]?.usedPercent == 63)
        assert(parsedCodex.readings[.codexWeekly]?.resetDescription == "08:59 on 17 Sep")
        assert(UsageClient.parseCodex(String(codex.dropLast())).readings.isEmpty)
        let onlySpark = codex.components(separatedBy: .newlines).filter { !$0.contains("37%") }.joined(separator: "\n")
        assert(UsageClient.parseCodex(onlySpark).readings.isEmpty)
        assert(UsageClient.parseCodex(codex.replacingOccurrences(of: "37%", with: "137%")).readings.isEmpty)
        assert(UsageClient.parseCodex(codex.replacingOccurrences(of: "37%", with: "0%")).readings[.codexWeekly]?.usedPercent == 100)
        assert(UsageClient.parseCodex(codex.replacingOccurrences(of: "37%", with: "100%")).readings[.codexWeekly]?.usedPercent == 0)

        var stream = Data()
        for fragment in ["\u{1B}[", "6", "n\u{1B}[3", "2m", codex, "\u{1B}[0m\u{1B}]0;private title", "\u{07}"] {
            stream.append(contentsOf: fragment.utf8)
        }
        assert(TerminalText.cursorQueryCount(in: stream) == 1)
        let cleaned = TerminalText.clean(String(decoding: stream, as: UTF8.self))
        assert(!cleaned.contains("\u{1B}") && !cleaned.contains("private title"))
        assert(UsageClient.parseCodex(cleaned).readings[.codexWeekly]?.usedPercent == 63)
        assert(UsageClient.parseClaude("\u{1B}[32m" + claude + "\u{1B}[0m").readings[.claudeFable]?.usedPercent == 34)
        for (percent, expected) in [(49.0, NSColor.systemGreen), (49.5, .systemGreen), (50, .systemOrange), (79, .systemOrange), (79.5, .systemOrange), (80, .systemRed)] {
            assert(MetricState(reading: UsageReading(usedPercent: percent, resetDescription: nil), updatedAt: Date()).color == expected)
        }
        assert(MetricState(reading: UsageReading(usedPercent: 30, resetDescription: nil), updatedAt: Date()).percentage == "70%")
        assert(MetricState().color == .secondaryLabelColor)
        assert(MetricState(reading: UsageReading(usedPercent: 80, resetDescription: nil), updatedAt: .distantPast).color == .secondaryLabelColor)
        print("Usage parser checks passed.")

        if CommandLine.arguments.contains("--lifecycle") {
            await checkLifecycle()
            await checkShellPath()
        }

        if CommandLine.arguments.contains("--live") {
            let path: String
            switch await ShellPath.load() {
            case .success(let captured): path = captured
            case .failure(let error):
                print(error.localizedDescription)
                exit(1)
            }
            var failed = false
            for provider in UsageProvider.allCases {
                let result = await UsageClient.fetch(provider, path: path)
                for metric in UsageMetric.allCases {
                    if let reading = result.readings[metric] {
                        print("\(metric.rawValue): \(reading.usedPercent)% used; resets \(reading.resetDescription ?? "unavailable")")
                    }
                }
                if let error = result.error {
                    print("\(provider.rawValue): \(error)")
                    failed = true
                }
            }
            UsageClient.cancelAll()
            if failed { exit(1) }
        }
    }

    static func checkLifecycle() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalPath = ProcessInfo.processInfo.environment["PATH"]
        defer {
            if let originalPath { setenv("PATH", originalPath, 1) } else { unsetenv("PATH") }
            unsetenv("AI_USAGE_TEST_PID_FILE")
            try? FileManager.default.removeItem(at: directory)
        }
        setenv("PATH", directory.path, 1)
        let missing = await UsageClient.fetch(.claude)
        assert(missing.readings.isEmpty && missing.error?.contains("PATH") == true)
        for provider in UsageProvider.allCases {
            let executable = directory.appendingPathComponent(provider.rawValue)
            let pidsFile = directory.appendingPathComponent("\(provider.rawValue).pids")
            setenv("AI_USAGE_TEST_PID_FILE", pidsFile.path, 1)
            try! #"""
            #!/bin/sh
            /bin/sleep 30 &
            child=$!
            printf '%s\n%s\n' "$$" "$child" > "$AI_USAGE_TEST_PID_FILE"
            wait "$child"
            """#.write(to: executable, atomically: true, encoding: .utf8)
            try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let task = Task { await UsageClient.fetch(provider) }
            let started = Date()
            var pids: [pid_t] = []
            while Date().timeIntervalSince(started) < 3 {
                pids = ((try? String(contentsOf: pidsFile, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { pid_t($0) }
                if pids.count == 2 { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            assert(pids.count == 2, "Fake CLI must launch before cancellation")
            if provider == .claude { task.cancel() } else { UsageClient.cancelAll() }
            let result = await task.value
            assert(result.readings.isEmpty && result.error?.contains("cancelled") == true)
            for _ in 0..<100 {
                if pids.allSatisfy({ kill($0, 0) != 0 }) { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            assert(pids.allSatisfy { kill($0, 0) != 0 }, "Cancellation must stop CLI children")
        }
        let codex = directory.appendingPathComponent("codex")
        try! "#!/bin/sh\nprintf 'model: mock\\n'\nexit 1\n".write(to: codex, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
        let earlyExit = await UsageClient.fetch(.codex)
        assert(earlyExit.readings.isEmpty && earlyExit.error != nil)
        print("CLI PATH, cancellation, child cleanup, and early-exit checks passed.")
        await checkRefresh(in: directory)
    }

    @MainActor
    static func checkRefresh(in directory: URL) async {
        setenv("AI_USAGE_TEST_DIRECTORY", directory.path, 1)
        defer { unsetenv("AI_USAGE_TEST_DIRECTORY") }
        let claude = directory.appendingPathComponent("claude")
        try! #"""
        #!/bin/sh
        i=1
        while ! /bin/mkdir "$AI_USAGE_TEST_DIRECTORY/request-$i" 2>/dev/null; do
            i=$((i + 1))
        done
        printf '%s' "$$" > "$AI_USAGE_TEST_DIRECTORY/request-$i/pid"
        while [ ! -e "$AI_USAGE_TEST_DIRECTORY/release-$i" ]; do /bin/sleep 0.02; done
        printf 'Current session: %s%% used\nCurrent week (all models): 19%% used\nCurrent week (Fable): 34%% used\n' "$((i * 10))"
        """#.write(to: claude, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: claude.path)
        let store = UsageStore(shellPath: Task { .success(directory.path) })
        defer { store.stop() }

        // Startup and two immediate menu openings must all start a request.
        for request in 1...3 {
            if request > 1 {
                NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: nil)
            }
            await waitUntil {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent("request-\(request)/pid").path)
            }
        }
        assert(store.refreshing.contains(.claude))
        try! Data().write(to: directory.appendingPathComponent("release-3"))
        await waitUntil { store.state(.claudeSession).reading?.usedPercent == 30 }
        for request in 1...2 {
            try! Data().write(to: directory.appendingPathComponent("release-\(request)"))
        }
        await waitUntil { store.refreshing.isEmpty }
        assert(store.state(.claudeSession).reading?.usedPercent == 30, "Older results must not overwrite the latest refresh")

        // Quitting must also cancel every overlapping request.
        var pids: [pid_t] = []
        for request in 4...5 {
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: nil)
            let file = directory.appendingPathComponent("request-\(request)/pid")
            await waitUntil { pid_t((try? String(contentsOf: file, encoding: .utf8)) ?? "") != nil }
            pids.append(pid_t(try! String(contentsOf: file, encoding: .utf8))!)
        }
        store.stop()
        await waitUntil { pids.allSatisfy { kill($0, 0) != 0 } }
        assert(store.refreshing.isEmpty)
        print("Menu-open refresh, overlapping requests, latest-result ordering, and stop checks passed.")
    }

    @MainActor
    static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<250 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        assert(condition(), "Timed out waiting for the fake CLI")
    }
}
