# AI Usage

A native macOS menu bar app showing Claude and Codex usage beside their logos. Click it for Claude session, Claude weekly, Claude Fable weekly, and Codex weekly allowances, including reset times. Percentages mean **remaining**. Readings come from the signed-in `claude` and `codex` CLIs on your shell's `PATH`.

![AI Usage menu bar dropdown](docs/screenshot.png)

## Install

```sh
brew install --cask tuckerritti/tap/ai-usage
```

Updates arrive with `brew upgrade`.

## Build and run

Requires macOS 14 or newer and Xcode.

```sh
./run.sh
```

This builds and launches `build/Build/Products/Release/AI Usage.app`. Quit an existing instance before rebuilding.

See [ATTRIBUTIONS.md](ATTRIBUTIONS.md) for logo sources.

## Release

Increment the version and build number in Xcode, push the changes to `main`, then push a matching tag such as `v1.0.2`. The Release workflow signs and notarizes the app, publishes its DMG, and updates [the Homebrew tap](https://github.com/tuckerritti/homebrew-tap).

To sync the tap with the latest published release without building again:

```sh
gh workflow run release.yml --ref main
```

The tap checkout uses the `HOMEBREW_TAP_SSH_KEY` Actions secret and a write-enabled deploy key restricted to the tap repository.
