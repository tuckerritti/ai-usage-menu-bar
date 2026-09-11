import Foundation

enum UsageProvider: String, CaseIterable, Sendable {
    case claude, codex
}

enum UsageMetric: String, CaseIterable, Sendable {
    case claudeSession, claudeWeekly, claudeFable, codexWeekly
}

struct UsageReading: Sendable {
    let usedPercent: Double
    let resetDescription: String?
}

struct UsageFetchResult: Sendable {
    let readings: [UsageMetric: UsageReading]
    let error: String?
}

enum UsageClient {
    private static let commands = ActiveCommands.shared

    static func fetch(_ provider: UsageProvider, path: String? = ProcessInfo.processInfo.environment["PATH"]) async -> UsageFetchResult {
        let command = CLICommand(provider: provider, path: path)
        commands.insert(command.managed)
        defer { commands.remove(command.managed) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: command.run())
                }
            }
        } onCancel: {
            command.managed.cancel()
        }
    }

    static func cancelAll() { commands.cancelAll() }

    static func parseClaude(_ output: String) -> UsageFetchResult {
        let text = TerminalText.clean(output)
        let labels: [(UsageMetric, String)] = [
            (.claudeSession, "Current session"),
            (.claudeWeekly, "Current week \\(all models\\)"),
            (.claudeFable, "Current week \\(Fable[^)]*\\)")
        ]
        var readings: [UsageMetric: UsageReading] = [:]
        for (metric, label) in labels {
            let pattern = "(?im)^" + label + ":\\s*([0-9]+(?:\\.[0-9]+)?)% used(?:[ \\t]*·[ \\t]*resets[ \\t]+([^\\r\\n]+))?[ \\t]*$"
            guard let match = captures(pattern, in: text),
                  let percent = Double(match[0]), (0...100).contains(percent) else { continue }
            readings[metric] = UsageReading(usedPercent: percent, resetDescription: match[1].nilIfEmpty)
        }
        let error: String?
        if readings.count == labels.count {
            error = nil
        } else if text.localizedCaseInsensitiveContains("rate limit") {
            error = "Claude usage is temporarily rate limited. Try again later."
        } else if readings.isEmpty {
            error = "Claude did not report usage. Run claude /usage in Terminal to check sign-in and CLI compatibility."
        } else {
            error = "Claude did not report every usage limit. Missing values are unavailable."
        }
        return UsageFetchResult(readings: readings, error: error)
    }

    static func parseCodex(_ output: String) -> UsageFetchResult {
        let text = TerminalText.clean(output)
        // Only complete boxes count: startup hints and partially drawn status must not become readings.
        let boxes = matches("(?s)╭[^╭╯]*╯", in: text)
        for box in boxes.reversed() {
            var mainLines: [String] = []
            for line in box.components(separatedBy: .newlines) {
                let row = line.trimmingCharacters(in: CharacterSet(charactersIn: "│ \t"))
                let lower = row.lowercased()
                if lower.contains(" limit:"), !lower.hasPrefix("weekly limit:"), !lower.hasPrefix("5h limit:") {
                    break // Additional model quotas, including Spark, are separate from the main quota.
                }
                mainLines.append(row)
            }
            let main = mainLines.joined(separator: "\n")
            guard let values = captures("(?i)Weekly limit:[ \\t]*(?:\\[[^\\]\\r\\n]*\\][ \\t]*)?([0-9]+(?:\\.[0-9]+)?)%[ \\t]+left(?:[ \\t]*\\(resets[ \\t]+([^\\)\\r\\n]+)\\))?", in: main),
                  let remaining = Double(values[0]), (0...100).contains(remaining) else { continue }
            return UsageFetchResult(readings: [.codexWeekly: UsageReading(usedPercent: 100 - remaining, resetDescription: values[1].nilIfEmpty)], error: nil)
        }
        return UsageFetchResult(readings: [:], error: "Codex did not report its weekly limit. Run codex /status in Terminal to check sign-in and CLI compatibility.")
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

// Parsing the accumulated stream also handles UTF-8 and ANSI sequences split across reads.
enum TerminalText {
    static func clean(_ text: String) -> String {
        var result = text
        for pattern in ["\\x1B\\][^\\x07\\x1B]*(?:\\x07|\\x1B\\\\)", "\\x1B\\[[0-?]*[ -/]*[@-~]", "\\x1B[()][A-Z0-9]", "\\x1B[@-_]"] {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func cursorQueryCount(in data: Data) -> Int {
        String(decoding: data, as: UTF8.self).components(separatedBy: "\u{1B}[6n").count - 1
    }
}

final class ActiveCommands: @unchecked Sendable {
    static let shared = ActiveCommands()
    private let lock = NSLock()
    private var entries: [UUID: ManagedProcess] = [:]

    func insert(_ command: ManagedProcess) { lock.lock(); defer { lock.unlock() }; entries[command.id] = command }
    func remove(_ command: ManagedProcess) { lock.lock(); defer { lock.unlock() }; entries[command.id] = nil }
    func cancelAll() {
        lock.lock()
        let current = Array(entries.values)
        lock.unlock()
        current.forEach { $0.cancel() }
    }
}

final class ManagedProcess: @unchecked Sendable {
    let id = UUID()
    let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var ownedGroup: (pid: pid_t, seconds: UInt64, microseconds: UInt64)?

    func launch() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        try process.run()
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        stopLocked()
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopLocked()
    }

    func recordOwnedGroup(_ child: pid_t) {
        lock.lock(); defer { lock.unlock() }
        if ownedGroup == nil, process.isRunning, Self.descendants(of: process.processIdentifier).contains(child),
           child > 1, getpgid(child) == child, child != getpgrp(), let start = Self.startTime(of: child) {
            ownedGroup = (child, start.0, start.1)
        }
    }

    private func stopLocked() {
        if process.isRunning {
            let root = process.processIdentifier
            let children = Self.descendants(of: root)
            // Discover children even before the marker arrives; never signal an inherited/app process group.
            for child in children.reversed() where child > 1 {
                if getpgid(child) == child, child != getpgrp() { kill(-child, SIGKILL) }
                kill(child, SIGKILL)
            }
            kill(root, SIGKILL)
        }
        // A wrapper can exit first. Check the recorded leader's birth time to avoid a recycled PID.
        if let group = ownedGroup, let start = Self.startTime(of: group.pid),
           start == (group.seconds, group.microseconds), group.pid > 1, group.pid != getpgrp(), getpgid(group.pid) == group.pid {
            kill(-group.pid, SIGKILL)
        }
    }

    private static func startTime(of pid: pid_t) -> (UInt64, UInt64)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return (info.pbi_start_tvsec, info.pbi_start_tvusec)
    }

    private static func descendants(of parent: pid_t) -> [pid_t] {
        // ponytail: probes normally have few children; size dynamically if shell startup exceeds 256.
        var pids = [pid_t](repeating: 0, count: 256)
        let count = pids.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        let children = Array(pids.prefix(Int(count))).filter { $0 > 1 }
        return children + children.flatMap { descendants(of: $0) }
    }
}

private final class CLICommand: @unchecked Sendable {
    let managed = ManagedProcess()
    private let provider: UsageProvider
    private let path: String?
    private var process: Process { managed.process }

    init(provider: UsageProvider, path: String?) {
        self.provider = provider
        self.path = path
    }

    func run() -> UsageFetchResult {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        let workingDirectory = FileManager.default.temporaryDirectory
        guard let executable = Self.resolve(provider.rawValue, path: environment["PATH"], relativeTo: workingDirectory) else {
            return failure("\(provider.rawValue) was not found on your shell's PATH. Update your shell configuration and relaunch AI Usage.")
        }
        let input = Pipe()
        let output = Pipe()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        process.currentDirectoryURL = workingDirectory
        if provider == .claude {
            environment["CLAUDE_CODE_SKIP_PROMPT_HISTORY"] = "1"
            environment["DISABLE_AUTOUPDATER"] = "1"
            process.executableURL = executable
            process.arguments = ["--safe-mode", "--permission-mode", "plan", "--tools", "", "--no-session-persistence", "--print", "/usage"]
        } else {
            environment["TERM"] = "xterm-256color"
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = ["-q", "/dev/null", "/bin/sh", "-c",
                #"printf '__AI_USAGE_CHILD__%s\n' "$$"; /bin/stty rows 60 cols 180; exec "$@""#,
                "ai-usage", executable.path, "--no-alt-screen", "-s", "read-only", "-a", "never",
                "--disable", "hooks", "--disable", "plugins", "--disable", "apps", "-c", "mcp_servers={}",
                "-c", #"history.persistence="none""#, "-c", "check_for_update_on_startup=false", "-c", "disable_paste_burst=true"]
        }
        process.environment = environment
        do {
            guard try managed.launch() else { return failure("Refresh cancelled.") }
        } catch { return failure("Could not launch \(provider.rawValue): \(error.localizedDescription)") }
        defer {
            managed.stop()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        try? output.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let started = Date()
        var queryCount = 0
        var statusTypedAt: Date?
        var statusSubmitted = false
        var successfulResult: UsageFetchResult?
        var quitAt: Date?
        while Date().timeIntervalSince(started) < 20 {
            if managed.isCancelled { return failure("Refresh cancelled.") }
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                if data.count > 1_048_576 { return failure("\(provider.rawValue) returned too much output.") }
                if provider == .codex {
                    let queries = TerminalText.cursorQueryCount(in: data)
                    while queryCount < queries {
                        send("\u{1B}[1;1R", to: input)
                        queryCount += 1
                    }
                    let raw = String(decoding: data, as: UTF8.self)
                    recordOwnedGroup(in: raw)
                    let text = TerminalText.clean(raw)
                    // The first prompt is painted while the model is still loading and drops input.
                    if statusTypedAt == nil, text.range(of: #"model:[ \t]+(?!loading\b)\S+"#, options: .regularExpression) != nil {
                        send("/status", to: input)
                        statusTypedAt = Date()
                    }
                    if statusSubmitted, successfulResult == nil {
                        let parsed = UsageClient.parseCodex(raw)
                        if parsed.error == nil {
                            successfulResult = parsed
                            send("/quit\r", to: input)
                            quitAt = Date()
                        }
                    }
                }
            }
            if let typed = statusTypedAt, !statusSubmitted, Date().timeIntervalSince(typed) >= 1 {
                send("\r", to: input)
                statusSubmitted = true
            }
            if let quitAt, Date().timeIntervalSince(quitAt) > 1 { return successfulResult! }
            if !process.isRunning, count <= 0 {
                if let successfulResult { return successfulResult }
                let parsed = provider == .claude ? UsageClient.parseClaude(String(decoding: data, as: UTF8.self)) : UsageClient.parseCodex(String(decoding: data, as: UTF8.self))
                if process.terminationStatus == 0 { return parsed }
                return UsageFetchResult(readings: parsed.readings, error: "\(provider.rawValue) exited with status \(process.terminationStatus). Run its usage command in Terminal to check sign-in and CLI compatibility.")
            }
            if count <= 0 { usleep(20_000) }
        }
        if let successfulResult { return successfulResult }
        let partial = provider == .claude ? UsageClient.parseClaude(String(decoding: data, as: UTF8.self)).readings : [:]
        return UsageFetchResult(readings: partial, error: "\(provider.rawValue) usage timed out. Run its usage command in Terminal to check sign-in or startup prompts.")
    }

    private func send(_ text: String, to pipe: Pipe) {
        try? pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
    }

    private func failure(_ message: String) -> UsageFetchResult { UsageFetchResult(readings: [:], error: message) }

    private static func resolve(_ name: String, path: String?, relativeTo directory: URL) -> URL? {
        guard let path else { return nil }
        for component in path.components(separatedBy: ":") {
            let folder = component.isEmpty ? directory : URL(fileURLWithPath: component, relativeTo: directory)
            let url = folder.appendingPathComponent(name).standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    private func recordOwnedGroup(in text: String) {
        guard let range = text.range(of: "__AI_USAGE_CHILD__"),
              let child = pid_t(text[range.upperBound...].prefix(while: \.isNumber)) else { return }
        managed.recordOwnedGroup(child)
    }
}
