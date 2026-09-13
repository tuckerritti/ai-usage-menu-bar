#!/bin/bash
set -euo pipefail

# Prints the Homebrew cask for a published release.
# Usage: scripts/homebrew-cask.sh AI-Usage-<version>-<build>.dmg.sha256 > Casks/ai-usage.rb

[[ $# -eq 1 && -f $1 ]] || { printf 'Usage: %s <dmg.sha256>\n' "$0" >&2; exit 1; }
read -r sha256 filename <"$1"
[[ $sha256 =~ ^[0-9a-f]{64}$ && $filename =~ ^AI-Usage-([0-9]+(\.[0-9]+)*)-([A-Za-z0-9._-]+)\.dmg$ ]] \
    || { printf 'Unrecognized checksum file: %s\n' "$1" >&2; exit 1; }
version=${BASH_REMATCH[1]}
build=${BASH_REMATCH[3]}

cat <<CASK
cask "ai-usage" do
  version "$version,$build"
  sha256 "$sha256"

  url "https://github.com/tuckerritti/ai-usage-menu-bar/releases/download/v#{version.csv.first}/AI-Usage-#{version.csv.first}-#{version.csv.second}.dmg"
  name "AI Usage"
  desc "Menu bar app showing Claude and Codex usage"
  homepage "https://github.com/tuckerritti/ai-usage-menu-bar"

  depends_on macos: :sonoma

  app "AI Usage.app"

  uninstall quit: "com.tuckerritti.AIUsage"
end
CASK
