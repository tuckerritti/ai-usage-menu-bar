#!/bin/bash
set -euo pipefail

# Exercise release gates without Xcode builds, signing, mounting, or network calls.
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
mkdir "$test_dir/bin"
cat >"$test_dir/bin/mock" <<'MOCK'
#!/bin/bash
set -euo pipefail
tool=${0##*/}
printf '%s %s\n' "$tool" "$*" >>"$MOCK_DIR/commands"
after() {
    local wanted=$1
    shift
    while [[ $# -gt 0 ]]; do
        if [[ $1 == "$wanted" ]]; then shift; printf '%s' "$1"; return; fi
        shift
    done
    return 1
}
case "$tool" in
    security)
        printf '  1) MOCK "%s"\n  1 valid identities found\n' "$DEVELOPER_ID_APPLICATION"
        ;;
    xcodebuild)
        app="$(after -derivedDataPath "$@")/Build/Products/Release/AI Usage.app"
        mkdir -p "$app/Contents/MacOS"
        printf 'fake binary' >"$app/Contents/MacOS/AI Usage"
        cat >"$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>1.2.3</string>
<key>CFBundleVersion</key><string>42</string>
</dict></plist>
PLIST
        ;;
    codesign)
        if [[ " $* " == *' --display '* ]]; then
            if [[ " $* " == *' --entitlements '* ]]; then
                if [[ $MOCK_MODE == entitlement ]]; then
                    printf '<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>\n'
                else
                    printf '<plist version="1.0"><dict/></plist>\n'
                fi
            else
                if [[ $MOCK_MODE == runtime ]]; then
                    printf 'CodeDirectory v=20500 size=123 flags=0x0(none)\n'
                else
                    printf 'CodeDirectory v=20500 size=123 flags=0x10000(runtime)\n'
                fi
                printf 'Authority=%s\nTimestamp=Jan 1, 2026 at 12:00:00 AM\n' "$DEVELOPER_ID_APPLICATION"
            fi
        fi
        ;;
    lipo)
        [[ $# -eq 4 && -f $1 && $2 == -verify_arch && $3 == arm64 && $4 == x86_64 ]]
        ;;
    hdiutil)
        case "$1" in
            create)
                after -srcfolder "$@" >"$MOCK_DIR/staging"
                printf 'mock disk image\n' >"${!#}"
                ;;
            attach)
                mount_dir=$(after -mountpoint "$@")
                cp -R "$(cat "$MOCK_DIR/staging")/." "$mount_dir/"
                ;;
            detach) ;;
            *) exit 2 ;;
        esac
        ;;
    xcrun)
        if [[ $1 == notarytool && $2 == submit ]]; then
            [[ " $* " == *' --keychain-profile '* && " $* " == *' --wait '* ]]
            if [[ -n "${NOTARYTOOL_KEYCHAIN:-}" ]]; then
                [[ $(after --keychain "$@") == "$NOTARYTOOL_KEYCHAIN" ]]
            else
                [[ " $* " != *' --keychain '* ]]
            fi
            if [[ $MOCK_MODE == invalid ]]; then
                printf '{"id":"mock-submission","status":"Invalid"}\n'
            else
                printf '{"id":"mock-submission","status":"Accepted"}\n'
            fi
        elif [[ $1 == stapler ]]; then
            [[ $MOCK_MODE != staple ]]
        else
            exit 2
        fi
        ;;
    spctl)
        [[ $MOCK_MODE != gatekeeper ]]
        ;;
    *) exit 2 ;;
esac
MOCK
chmod +x "$test_dir/bin/mock"
for tool in security xcodebuild codesign lipo hdiutil xcrun spctl; do
    ln -s mock "$test_dir/bin/$tool"
done

run_case() {
    local mode=$1 expected=$2 result=0
    local case_dir="$test_dir/$mode"
    mkdir "$case_dir"
    PATH="$test_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        DEVELOPER_ID_APPLICATION='Developer ID Application: Mock Developer (MOCKTEAM01)' \
        NOTARYTOOL_PROFILE='mock-keychain-profile' RELEASE_DIR="$case_dir/releases" \
        MOCK_DIR="$case_dir" MOCK_MODE="$mode" \
        "$repo_dir/scripts/release.sh" >"$case_dir/output" 2>&1 || result=$?
    local artifact="$case_dir/releases/AI-Usage-1.2.3-42.dmg"
    if [[ $expected == success ]]; then
        [[ $result -eq 0 ]] || { cat "$case_dir/output"; exit 1; }
        [[ -f "$artifact" && -f "$artifact.sha256" && -f "$artifact.notarization.json" ]]
        (cd "$case_dir/releases" && shasum -a 256 -c AI-Usage-1.2.3-42.dmg.sha256 >/dev/null)
        [[ $(grep -c 'xcrun notarytool submit' "$case_dir/commands") -eq 1 ]]
        grep -F 'xcrun stapler validate' "$case_dir/commands" >/dev/null
        grep -F 'spctl --assess --type execute' "$case_dir/commands" >/dev/null
    else
        [[ $result -ne 0 && ! -e "$artifact" && ! -e "$artifact.sha256" ]] \
            || { cat "$case_dir/output"; printf 'Expected a closed release gate: %s\n' "$mode" >&2; exit 1; }
        case "$mode" in
            runtime|entitlement) ! grep -F 'xcrun notarytool submit' "$case_dir/commands" >/dev/null ;;
            invalid) ! grep -F 'xcrun stapler staple' "$case_dir/commands" >/dev/null ;;
        esac
    fi
}

run_case accepted success
NOTARYTOOL_KEYCHAIN="$test_dir/runner signing.keychain-db" run_case custom_keychain success
run_case runtime failure
run_case entitlement failure
run_case invalid failure
run_case staple failure
run_case gatekeeper failure
printf 'Release mock checks passed: accepted artifact/checksum; runtime, entitlement, notarization, stapling, and Gatekeeper failure gates.\n'

# Homebrew cask generation from a published checksum file.
printf 'c1f1359a19663f06e4c4b886634e17a139dea513a14ffd58860e61d8455c0453  AI-Usage-1.2.3-42.dmg\n' >"$test_dir/cask.sha256"
cask=$("$repo_dir/scripts/homebrew-cask.sh" "$test_dir/cask.sha256")
[[ $cask == *'version "1.2.3,42"'* && $cask == *'sha256 "c1f1359a19663f06e4c4b886634e17a139dea513a14ffd58860e61d8455c0453"'* ]]
printf 'not-a-checksum  AI-Usage-1.2.3-42.dmg\n' >"$test_dir/bad.sha256"
! "$repo_dir/scripts/homebrew-cask.sh" "$test_dir/bad.sha256" 2>/dev/null
printf 'Homebrew cask checks passed.\n'
