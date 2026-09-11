#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 6 -parse-as-library AIUsage/UsageClient.swift AIUsage/ShellPath.swift AIUsage/UsageStore.swift Tests/UsageChecks.swift Tests/ShellPathChecks.swift -o "$check_dir/usage-checks"
"$check_dir/usage-checks" "$@"
