# AI Usage

A native macOS menu bar app showing Claude session usage and Codex weekly usage beside their logos. Click it for Claude session, Claude weekly, Claude Fable weekly, and Codex weekly allowances, including reset times.

Percentages mean **used**: green below 50%, orange from 50% to under 80%, red at 80% and above. Readings refresh every minute, at launch, and after wake. Refresh and Quit are available in the dropdown.

## Build and run

Requires macOS 14 or newer, Xcode, and signed-in `claude` and `codex` executables on `PATH`.

```sh
./run.sh
```

This builds `build/Build/Products/Release/AI Usage.app` and launches it with your current `PATH`, unchanged. Quit an existing instance before rebuilding to pick up code changes. The app searches **only PATH** for both CLIs. Finder and Xcode can have a different PATH from your Terminal; use the launcher to pass your existing Terminal PATH through. No installation directories or fallback paths are built into the app.

Open `AIUsage.xcodeproj` to work in Xcode. The project uses local ad-hoc signing, has no external dependencies, and disables App Sandbox so the installed CLIs can access their own authentication.

To build without launching:

```sh
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage \
  -configuration Release -derivedDataPath build build
```

## Checks

```sh
./Tests/check.sh
./Tests/check.sh --lifecycle
./Tests/check.sh --live
```

The first command runs local parser and color regression checks. The lifecycle option checks missing PATH entries, cancellation, child cleanup, and early CLI exit using temporary fake executables. The live check invokes the installed CLIs, prints only parsed usage results/errors, and fails if either provider cannot report every requested reading.

## How usage is read

Claude uses `claude --safe-mode --permission-mode plan --tools '' --no-session-persistence --print /usage`. Codex uses its interactive `/status` command through macOS's built-in terminal wrapper, then `/quit`. The Codex main weekly limit is converted from percent remaining to percent used; model-specific Spark quotas are excluded.

These commands use the CLIs' existing sign-ins and do not send model prompts. Background probes disable hooks, plugins, automatic updates, and other unnecessary startup integrations. CLI output stays in memory; the app does not copy credentials or save transcripts.

Missing data displays a dash. Failed refreshes preserve previous readings in gray with a stale indicator and an explanation in the dropdown. Missing executables, sign-in issues, unsupported CLI output, and timeouts remain visible rather than displaying zero usage.

The parsers were validated against Claude Code 2.1.268 and Codex CLI 0.154.0. CLI output formats can change; the local checks cover the captured formats. See [ATTRIBUTIONS.md](ATTRIBUTIONS.md) for logo sources.
