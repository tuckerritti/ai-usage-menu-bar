# AI Usage

A native macOS menu bar app showing Claude and Codex usage beside their logos. Click it for Claude session, Claude weekly, Claude Fable weekly, and Codex weekly allowances, including reset times. Percentages mean **remaining**. Readings come from the signed-in `claude` and `codex` CLIs on your shell's `PATH`.

![AI Usage menu bar dropdown](docs/screenshot.png)

## Build and run

Requires macOS 14 or newer and Xcode.

```sh
./run.sh
```

This builds and launches `build/Build/Products/Release/AI Usage.app`. Quit an existing instance before rebuilding.

See [ATTRIBUTIONS.md](ATTRIBUTIONS.md) for logo sources.
