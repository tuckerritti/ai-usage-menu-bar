# AI Usage

A native macOS menu bar app showing Claude session usage and Codex weekly usage beside their logos. Click it for Claude session, Claude weekly, Claude Fable weekly, and Codex weekly allowances, including reset times.

Percentages and bars mean **remaining**: green above 50%, orange from 50% down to just above 20%, red at 20% and below. Readings refresh every minute, at launch, after wake, and every time the dropdown opens. Quit is available in the dropdown. Refreshes can overlap; older requests cannot overwrite the latest refresh's results.

## Build and run

Requires macOS 14 or newer and signed-in `claude` and `codex` executables on your shell's `PATH`. Xcode is needed to build the app.

```sh
./run.sh
```

This builds and launches `build/Build/Products/Release/AI Usage.app`. Quit an existing instance before rebuilding to pick up code changes. Once built, the app can be opened directly from Finder.

At startup, the app opens your macOS account's configured shell in interactive login mode once, captures its `PATH`, and uses it to find and run both CLIs. All refreshes share that result. Shell startup has a five-second timeout; failure is shown in the dropdown. Fix the shell startup or PATH configuration and relaunch to try again. The app searches **only the captured PATH**, with no installation-directory fallbacks, and does not modify your shell configuration.

Open `AIUsage.xcodeproj` to work in Xcode. Local builds use ad-hoc signing. Distribution builds use the Developer ID release script below. The app has no external dependencies and disables App Sandbox so the installed CLIs can access their own authentication. Hardened Runtime is enabled.

To build without launching:

```sh
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage \
  -configuration Release -derivedDataPath build build
```

## Signed DMG releases

One-time setup on the Mac used for releases:

1. Sign in to your [Apple Developer account](https://developer.apple.com/account/) and accept any pending program agreement. In Xcode, open **Settings → Apple Accounts → your account → your team → Manage Certificates**, then create a **Developer ID Application** certificate. Its private key stays in Keychain. Apple Development and Apple Distribution certificates are not substitutes for Developer ID when distributing this DMG outside the App Store. See [Apple's certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).
2. Create an [app-specific password](https://support.apple.com/en-us/102654) in your Apple Account, then save notarization credentials using the secure Terminal prompt below. Replace the account and team values. Do not put the password in the command, repository, or chat.

```sh
xcrun notarytool store-credentials ai-usage-notary \
  --apple-id 'YOUR_APPLE_ID' --team-id 'YOUR_TEAM_ID'
```

Find the installed certificate's exact name with `security find-identity -v -p codesigning`, then build the release:

```sh
DEVELOPER_ID_APPLICATION='Developer ID Application: Your Name (TEAMID)' \
NOTARYTOOL_PROFILE='ai-usage-notary' ./scripts/release.sh
```

The script builds for Apple Silicon and Intel, verifies Developer ID signatures, Hardened Runtime, secure timestamps, and the absence of debugging entitlements. It packages the app with an Applications shortcut, signs the DMG, submits it to Apple, waits for acceptance, staples the notarization ticket, and checks Gatekeeper on the DMG and its app. Credentials are read from the named Keychain profile; the script never accepts passwords or private keys.

Successful artifacts appear in `build/releases/`: `AI-Usage-<version>-<build>.dmg`, its `.sha256` checksum, and Apple's `.notarization.json` response. Set `RELEASE_DIR` to change the output directory. Increment `MARKETING_VERSION` or `CURRENT_PROJECT_VERSION` before a new release; existing artifacts are not overwritten. Failed attempts retain their diagnostics in the reported work directory and do not produce a completed release. A notarization timeout may leave Apple's submission processing; inspect its saved submission ID before submitting again.

This follows [Apple's outermost-container notarization workflow](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution). Set `NOTARYTOOL_KEYCHAIN` when the notarization profile is stored in a specific file keychain, as it is on the GitHub runner.

## GitHub Actions

The repository is [tuckerritti/ai-usage-menu-bar](https://github.com/tuckerritti/ai-usage-menu-bar). It is private, so its releases are available to people with repository access.

The CI workflow runs on pull requests and pushes to `main`. It checks parsers, shell capture and process lifecycle, release failure handling, and a universal macOS Release build. These checks use fake CLIs and do not require Claude or Codex sign-ins.

The release workflow runs when a `v*` tag is pushed. The tag must match the app's `MARKETING_VERSION` (for example, `v1.0`), and its commit must be on `main`. Checks run before signing credentials are loaded. The job then runs `scripts/release.sh`, uploads the notarized DMG and SHA-256 checksum to a draft GitHub Release, and publishes it after the uploads succeed. Existing releases are not overwritten.

The signing job uses these **Actions secrets** under repository Settings → Secrets and variables → Actions:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64-encoded, password-protected PKCS#12 export containing the Developer ID Application certificate and its private key |
| `DEVELOPER_ID_P12_PASSWORD` | Password protecting that export |
| `NOTARIZATION_PASSWORD` | Apple app-specific password for notarization |

Repository **Actions variables** contain `APPLE_ID`, `APPLE_TEAM_ID`, and `DEVELOPER_ID_APPLICATION` (the full certificate name). The runner imports the certificate and notarization profile into a temporary keychain and removes it when the job finishes. Never commit these secrets or place them in workflow YAML. See [GitHub's signing guidance](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).

To save or rotate the notarization secret, run this command and enter the Apple app-specific password at the hidden prompt:

```sh
gh secret set NOTARIZATION_PASSWORD --app actions --repo tuckerritti/ai-usage-menu-bar
```

To release the current `1.0` version after its changes are pushed to `main`:

```sh
git tag -a v1.0 -m 'AI Usage 1.0'
git push origin v1.0
```

For later releases, update `MARKETING_VERSION` in both Xcode configurations, increment `CURRENT_PROJECT_VERSION`, commit and push, then tag that version. Signing and notarization happen on GitHub's macOS runner; the local Mac does not need to remain on.

## Checks

```sh
./Tests/check.sh
./Tests/check.sh --lifecycle
./Tests/check.sh --live
./Tests/ReleaseChecks.sh
ruby ./Tests/WorkflowChecks.rb
```

The first command runs local parser and color regression checks. The lifecycle option uses temporary fake executables to check shell PATH capture and reuse, child environment propagation, timeouts, cancellation, child cleanup, early CLI exit, and overlapping menu-open refreshes. The live check uses your configured shell's PATH to invoke the installed CLIs, prints only parsed usage results/errors, and fails if either provider cannot report every requested reading.

The release check uses mocked signing and notarization tools to exercise the release script's success and failure paths. It does not sign or submit software to Apple.

The workflow check validates YAML and shell syntax and exercises the tag, version, source, and draft-publication checks without contacting GitHub or loading credentials.

## How usage is read

Claude uses `claude --safe-mode --permission-mode plan --tools '' --no-session-persistence --print /usage`. Codex uses its interactive `/status` command through macOS's built-in terminal wrapper, then `/quit`. The Codex main weekly limit is converted from percent remaining to percent used; model-specific Spark quotas are excluded.

These commands use the CLIs' existing sign-ins and do not send model prompts. Background probes disable hooks, plugins, automatic updates, and other unnecessary startup integrations. CLI output stays in memory; the app does not copy credentials or save transcripts.

Missing data displays a dash. Failed refreshes preserve previous readings in gray with a stale indicator and an explanation in the dropdown. Missing executables, sign-in issues, unsupported CLI output, and timeouts remain visible rather than displaying zero usage.

The parsers were validated against Claude Code 2.1.268 and Codex CLI 0.154.0. CLI output formats can change; the local checks cover the captured formats. See [ATTRIBUTIONS.md](ATTRIBUTIONS.md) for logo sources.
