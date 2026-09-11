import AppKit
import Foundation

extension UsageChecks {
    @MainActor
    static func checkShellPath() async {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("ai-usage-shell-path-\(UUID().uuidString)")
        try! files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let parentPath = ProcessInfo.processInfo.environment["PATH"]
        let bin = directory.appendingPathComponent("bin space '\" $value $(printf changed) `printf changed` ")
        try! files.createDirectory(at: bin, withIntermediateDirectories: true)
        let expectedPath = bin.path
        assert(expectedPath.hasSuffix(" "))

        func executable(_ url: URL, _ body: String) -> URL {
            try! ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try! files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        let calls = directory.appendingPathComponent("shell-calls")
        let shell = executable(directory.appendingPathComponent("fake-shell"), #"""
        [ "$1" = '-ilc' ] && [ "$#" = 2 ] || exit 9
        printf 'called\n' >> "$AI_USAGE_SHELL_CALLS"
        printf 'startup stdout: $PATH is not a value\n'
        printf 'startup stderr: unrelated text\n' >&2
        /bin/sleep 0.1
        export PATH="$AI_USAGE_EXPECTED_PATH"
        for last do :; done
        /bin/sh -c "$last"
        printf 'after capture stdout\n'
        printf 'after capture stderr\n' >&2
        """#)
        var environment = ["PATH": "/usr/bin:/bin", "AI_USAGE_SHELL_CALLS": calls.path, "AI_USAGE_EXPECTED_PATH": expectedPath]
        guard case .success(let path) = await ShellPath.load(shell: shell, environment: environment) else {
            fatalError("Noisy fake shell must return its marked PATH")
        }
        assert(path == expectedPath, "PATH must preserve literal quotes, shell text, spaces, and the trailing space")
        assert(ProcessInfo.processInfo.environment["PATH"] == parentPath)

        _ = executable(bin.appendingPathComponent("claude"), "exec ai-usage-path-helper")
        _ = executable(bin.appendingPathComponent("ai-usage-path-helper"), #"""
        printf 'Current session: 42%% used\nCurrent week (all models): 19%% used\nCurrent week (Fable): 34%% used\n'
        """#)
        let direct = await UsageClient.fetch(.claude, path: path)
        assert(direct.error == nil && direct.readings[.claudeSession]?.usedPercent == 42,
               "The CLI must inherit the captured PATH so it can execute a helper by name")
        assert(ProcessInfo.processInfo.environment["PATH"] == parentPath)

        let storeCalls = directory.appendingPathComponent("store-shell-calls")
        environment["AI_USAGE_SHELL_CALLS"] = storeCalls.path
        let storeEnvironment = environment
        let sharedPath = Task { await ShellPath.load(shell: shell, environment: storeEnvironment) }
        let store = UsageStore(shellPath: sharedPath)
        store.refresh()
        store.refresh()
        await waitUntil { store.state(.claudeSession).reading?.usedPercent == 42 && store.refreshing.isEmpty }
        assert((try! String(contentsOf: storeCalls, encoding: .utf8)).split(separator: "\n").count == 1,
               "Overlapping provider refreshes must share one shell invocation")
        store.stop()
        assert(ProcessInfo.processInfo.environment["PATH"] == parentPath)

        let missing = executable(directory.appendingPathComponent("missing-capture"), "printf 'no marker here\\n'")
        switch await ShellPath.load(shell: missing, environment: environment) {
        case .failure(.pathUnavailable): break
        default: assertionFailure("Unmarked output must not become PATH")
        }
        var emptyEnvironment = environment
        emptyEnvironment["AI_USAGE_EXPECTED_PATH"] = ""
        switch await ShellPath.load(shell: shell, environment: emptyEnvironment) {
        case .failure(.pathUnavailable): break
        default: assertionFailure("An empty captured PATH must be unavailable")
        }
        let nonzero = executable(directory.appendingPathComponent("nonzero-shell"), "exit 7")
        switch await ShellPath.load(shell: nonzero, environment: environment) {
        case .failure(.pathUnavailable): break
        default: assertionFailure("Nonzero shell exit without PATH must fail")
        }
        switch await ShellPath.load(shell: directory.appendingPathComponent("does-not-exist"), environment: environment) {
        case .failure(.launchFailed): break
        default: assertionFailure("A missing executable must report launch failure")
        }
        let noisy = executable(directory.appendingPathComponent("oversized-shell"), "/usr/bin/head -c 1048577 /dev/zero")
        switch await ShellPath.load(shell: noisy, environment: environment) {
        case .failure(.outputTooLarge): break
        default: assertionFailure("Shell output must be capped at one MiB")
        }

        let hanging = executable(directory.appendingPathComponent("hanging-shell"), #"""
        /bin/sleep 30 &
        child=$!
        printf '%s\n%s\n' "$$" "$child" > "$AI_USAGE_SHELL_PIDS"
        wait "$child"
        """#)
        for cancel in [false, true] {
            let pidsFile = directory.appendingPathComponent(cancel ? "cancel.pids" : "timeout.pids")
            var hangingEnvironment = environment
            hangingEnvironment["AI_USAGE_SHELL_PIDS"] = pidsFile.path
            let fixtureEnvironment = hangingEnvironment
            let task = Task { await ShellPath.load(shell: hanging, environment: fixtureEnvironment, timeout: cancel ? 5 : 0.3) }
            func pids() -> [pid_t] {
                ((try? String(contentsOf: pidsFile, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { pid_t($0) }
            }
            await waitUntil { pids().count == 2 }
            let ownedPIDs = pids()
            if cancel { task.cancel() }
            switch (cancel, await task.value) {
            case (false, .failure(.timedOut)), (true, .failure(.cancelled)): break
            default: assertionFailure("A hanging shell must return its bounded timeout or cancellation error")
            }
            await waitUntil { ownedPIDs.allSatisfy { kill($0, 0) != 0 } }
        }
        assert(ProcessInfo.processInfo.environment["PATH"] == parentPath)
        print("Shell PATH capture, child PATH propagation, shared startup, failure, timeout, and cancellation checks passed.")
    }
}
