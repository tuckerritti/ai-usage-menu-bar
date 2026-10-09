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

    static let codexRequests = [
        #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"ai-usage","version":"1"}}}"#,
        #"{"method":"initialized"}"#,
        #"{"id":2,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":true}}"#
    ].map { $0 + "\n" }.joined()

    /// Reads the `codex app-server` reply to request 2; nil until that reply arrives.
    static func parseCodex(_ output: String) -> UsageFetchResult? {
        let replies = output.split(whereSeparator: \.isNewline).compactMap {
            try? JSONDecoder().decode(CodexReply.self, from: Data($0.utf8))
        }
        guard let reply = replies.first(where: { $0.id == 2 }) else { return nil }
        if let error = reply.error {
            return UsageFetchResult(readings: [:], error: "Codex could not read usage: \(error.message)")
        }
        let windows = [reply.result?.rateLimits.primary, reply.result?.rateLimits.secondary].compactMap { $0 }
        guard let weekly = windows.first(where: { $0.windowDurationMins == 10_080 }), (0...100).contains(weekly.usedPercent) else {
            return UsageFetchResult(readings: [:], error: "Codex did not report its weekly limit. Run codex /status in Terminal to check sign-in and CLI compatibility.")
        }
        let reset = weekly.resetsAt.map { seconds in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "h:mm a 'on' d MMM"
            return formatter.string(from: Date(timeIntervalSince1970: seconds))
        }
        return UsageFetchResult(readings: [.codexWeekly: UsageReading(usedPercent: weekly.usedPercent, resetDescription: reset)], error: nil)
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

private struct CodexReply: Decodable {
    struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int?
        let resetsAt: Double?
    }
    struct Limits: Decodable {
        let primary: Window?
        let secondary: Window?
    }
    struct Result: Decodable { let rateLimits: Limits }
    struct Failure: Decodable { let message: String }
    let id: Int?
    let result: Result?
    let error: Failure?
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

    private func stopLocked() {
        if process.isRunning {
            let root = process.processIdentifier
            let children = Self.descendants(of: root)
            // Never signal an inherited/app process group.
            for child in children.reversed() where child > 1 {
                if getpgid(child) == child, child != getpgrp() { kill(-child, SIGKILL) }
                kill(child, SIGKILL)
            }
            kill(root, SIGKILL)
        }
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
        // The CLIs index their working directory, and the shared temp folder holds thousands of files.
        var workingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("AI Usage", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        } catch {
            workingDirectory = FileManager.default.temporaryDirectory
        }
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
            // The app server answers rate limits without starting a session, MCP servers, or a terminal UI.
            // Plugins would make it fetch marketplaces from GitHub on every start.
            process.executableURL = executable
            process.arguments = ["app-server", "--disable", "plugins"]
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
        if provider == .codex { send(UsageClient.codexRequests, to: input) }
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let started = Date()
        while Date().timeIntervalSince(started) < 20 {
            if managed.isCancelled { return failure("Refresh cancelled.") }
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                if data.count > 1_048_576 { return failure("\(provider.rawValue) returned too much output.") }
                if provider == .codex, let result = UsageClient.parseCodex(String(decoding: data, as: UTF8.self)) { return result }
            }
            if !process.isRunning, count <= 0 {
                let text = String(decoding: data, as: UTF8.self)
                let parsed = provider == .claude ? UsageClient.parseClaude(text) : UsageClient.parseCodex(text) ?? failure("Codex did not answer its usage request.")
                if process.terminationStatus == 0 { return parsed }
                return UsageFetchResult(readings: parsed.readings, error: "\(provider.rawValue) exited with status \(process.terminationStatus). Run its usage command in Terminal to check sign-in and CLI compatibility.")
            }
            if count <= 0 { usleep(20_000) }
        }
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
}
