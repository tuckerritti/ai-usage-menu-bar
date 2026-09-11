import Foundation
import Darwin

enum ShellPathError: Error, Sendable, LocalizedError {
    case configuredShellUnavailable
    case launchFailed
    case timedOut
    case outputTooLarge
    case pathUnavailable
    case cancelled

    var errorDescription: String? {
        switch self {
        case .configuredShellUnavailable:
            return "Could not find your account's login shell. Check your default shell in Terminal and relaunch AI Usage."
        case .launchFailed:
            return "Could not start your login shell. Check that it runs in Terminal and relaunch AI Usage."
        case .timedOut:
            return "Your shell took too long to load PATH. Check its startup files for prompts or slow commands, then relaunch AI Usage."
        case .outputTooLarge:
            return "Your shell produced too much startup output. Check its startup files, then relaunch AI Usage."
        case .pathUnavailable:
            return "Your shell did not provide PATH. Check that its startup files export PATH and finish without exiting early, then relaunch AI Usage."
        case .cancelled:
            return "Shell PATH discovery was cancelled. Relaunch AI Usage to try again."
        }
    }
}

enum ShellPath {
    static func load(
        shell: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 5
    ) async -> Result<String, ShellPathError> {
        let managed = ManagedProcess()
        ActiveCommands.shared.insert(managed)
        defer { ActiveCommands.shared.remove(managed) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: capture(shell: shell, environment: environment, timeout: timeout, managed: managed))
                }
            }
        } onCancel: {
            managed.cancel()
        }
    }

    private static func capture(
        shell: URL?, environment: [String: String], timeout: TimeInterval, managed: ManagedProcess
    ) -> Result<String, ShellPathError> {
        if managed.isCancelled { return .failure(.cancelled) }
        guard let shell = shell ?? configuredShell() else { return .failure(.configuredShellUnavailable) }
        guard timeout.isFinite, timeout > 0 else { return .failure(.timedOut) }

        let marker = UUID().uuidString
        let begin = "AI_USAGE_PATH_BEGIN_\(marker)"
        let end = "AI_USAGE_PATH_END_\(marker)"
        let beginBytes = Data("\u{0}\(begin)\u{0}".utf8)
        let endBytes = Data("\u{0}\(end)\u{0}".utf8)
        let output = Pipe()
        let process = managed.process
        process.executableURL = shell
        process.arguments = ["-ilc", "/usr/bin/printf '\\000%s\\000' '\(begin)'; /usr/bin/printenv PATH; /usr/bin/printf '\\000%s\\000' '\(end)'"]
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        defer {
            managed.stop()
            try? output.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        do {
            guard try managed.launch() else { return .failure(.cancelled) }
        } catch { return .failure(.launchFailed) }
        try? output.fileHandleForWriting.close()

        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while ProcessInfo.processInfo.systemUptime < deadline {
            if managed.isCancelled { return .failure(.cancelled) }
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                if data.count > 1_048_576 { return .failure(.outputTooLarge) }
                if let start = data.range(of: beginBytes),
                   let finish = data.range(of: endBytes, in: start.upperBound..<data.endIndex) {
                    var value = Data(data[start.upperBound..<finish.lowerBound])
                    // printenv adds one newline; PATH itself can contain spaces or newlines.
                    guard value.last == 10 else { return .failure(.pathUnavailable) }
                    value.removeLast()
                    guard !value.isEmpty, !value.contains(0), let path = String(data: value, encoding: .utf8) else {
                        return .failure(.pathUnavailable)
                    }
                    return managed.isCancelled ? .failure(.cancelled) : .success(path)
                }
            }
            if !process.isRunning, count <= 0 {
                return .failure(managed.isCancelled ? .cancelled : .pathUnavailable)
            }
            if count <= 0 { usleep(20_000) }
        }
        return managed.isCancelled ? .failure(.cancelled) : .failure(.timedOut)
    }

    private static func configuredShell() -> URL? {
        let suggestedSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        var bufferSize = suggestedSize > 0 ? Int(suggestedSize) : 1024
        while bufferSize <= 1_048_576 {
            var entry = passwd()
            var result: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: bufferSize)
            let lookup = buffer.withUnsafeMutableBufferPointer { bytes -> (Int32, String?) in
                let status = getpwuid_r(getuid(), &entry, bytes.baseAddress, bytes.count, &result)
                let path = status == 0 && result != nil ? entry.pw_shell.map { String(cString: $0) } : nil
                return (status, path)
            }
            if lookup.0 == ERANGE { bufferSize *= 2; continue }
            guard lookup.0 == 0, let path = lookup.1, path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
