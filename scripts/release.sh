#!/bin/bash
set -euo pipefail

# Credentials stay in Keychain. This script never accepts passwords or private keys.
# DEVELOPER_ID_APPLICATION='Developer ID Application: Name (TEAMID)' \
# NOTARYTOOL_PROFILE='ai-usage-notary' ./scripts/release.sh
# Apple recommends notarizing/stapling the outermost distribution container:
# https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution

fail() { printf 'Release failed: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 0 ]] || fail 'No arguments are supported; configure the environment variables shown in this script.'
: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to the exact Developer ID Application certificate name.}"
: "${NOTARYTOOL_PROFILE:?Set NOTARYTOOL_PROFILE to an existing notarytool Keychain profile.}"
case "$DEVELOPER_ID_APPLICATION" in
    'Developer ID Application: '*) ;;
    *) fail 'A Developer ID Application identity is required; development and ad-hoc identities cannot release this app.' ;;
esac
security find-identity -v -p codesigning | grep -F -- "\"$DEVELOPER_ID_APPLICATION\"" >/dev/null \
    || fail 'The requested Developer ID Application identity is not available in Keychain.'

repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
release_dir=${RELEASE_DIR:-"$repo_dir/build/releases"}
mkdir -p -- "$release_dir"
release_dir=$(cd -- "$release_dir" && pwd)
work_dir=$(mktemp -d "$release_dir/.release-work.XXXXXX")
mounted=false
complete=false
cleanup() {
    if "$mounted"; then hdiutil detach "$work_dir/mounted" >/dev/null 2>&1 || true; fi
    if "$complete"; then
        rm -rf -- "$work_dir"
    else
        printf 'Release stopped. Diagnostic files remain in %s\n' "$work_dir" >&2
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Building universal Developer ID release…\n'
xcodebuild -quiet -project "$repo_dir/AIUsage.xcodeproj" -scheme AIUsage \
    -configuration Release -derivedDataPath "$work_dir/build" \
    'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$DEVELOPER_ID_APPLICATION" \
    ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS=--timestamp build
app="$work_dir/build/Build/Products/Release/AI Usage.app"

verify_app() {
    local bundle=$1 arch entitlements
    codesign --verify --deep --strict --all-architectures --verbose=2 "$bundle"
    lipo "$bundle/Contents/MacOS/AI Usage" -verify_arch arm64 x86_64
    for arch in arm64 x86_64; do
        codesign --display --arch "$arch" --verbose=4 "$bundle" >"$work_dir/signature-$arch.txt" 2>&1
        grep -Fx -- "Authority=$DEVELOPER_ID_APPLICATION" "$work_dir/signature-$arch.txt" >/dev/null \
            || fail "$arch was not signed with the requested Developer ID identity."
        grep -E '^CodeDirectory .*flags=.*\(.*runtime.*\)' "$work_dir/signature-$arch.txt" >/dev/null \
            || fail "Hardened Runtime is missing from the $arch signature."
        grep '^Timestamp=' "$work_dir/signature-$arch.txt" >/dev/null \
            || fail "A secure timestamp is missing from the $arch signature."
        entitlements="$work_dir/entitlements-$arch.plist"
        codesign --display --arch "$arch" --entitlements - --xml "$bundle" >"$entitlements" 2>/dev/null
        if [[ -s "$entitlements" ]]; then
            plutil -lint "$entitlements" >/dev/null
            if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$entitlements" >/dev/null 2>&1; then
                fail "The $arch release contains the get-task-allow entitlement."
            fi
        fi
    done
}
verify_app "$app"

version=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")
build_number=$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")
for component in "$version" "$build_number"; do
    case "$component" in
        ''|*[!A-Za-z0-9._-]*) fail 'The app version and build number must be set and suitable for a release filename.' ;;
    esac
done
filename="AI-Usage-$version-$build_number.dmg"
artifact="$release_dir/$filename"
[[ ! -e "$artifact" && ! -e "$artifact.sha256" ]] || fail "An artifact already exists at $artifact; increment the version/build or use a different RELEASE_DIR."

mkdir "$work_dir/staging"
ditto "$app" "$work_dir/staging/AI Usage.app"
ln -s /Applications "$work_dir/staging/Applications"
dmg="$work_dir/$filename"
hdiutil create -volname 'AI Usage' -srcfolder "$work_dir/staging" -format UDZO -fs HFS+ "$dmg"
codesign --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$dmg"
codesign --verify --strict --verbose=2 "$dmg"

printf 'Submitting signed DMG for notarization…\n'
notary_result="$work_dir/notarization.json"
notary_credentials=(--keychain-profile "$NOTARYTOOL_PROFILE")
if [[ -n "${NOTARYTOOL_KEYCHAIN:-}" ]]; then
    notary_credentials+=(--keychain "$NOTARYTOOL_KEYCHAIN")
fi
if ! xcrun notarytool submit "$dmg" "${notary_credentials[@]}" \
    --wait --timeout 30m --output-format json >"$notary_result"; then
    fail "Notarization did not complete successfully; inspect $notary_result before retrying."
fi
status=$(plutil -extract status raw -o - "$notary_result")
[[ "$status" == Accepted ]] || fail "Notarization status is $status; inspect $notary_result."
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
codesign --verify --strict --verbose=2 "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

mkdir "$work_dir/mounted"
hdiutil attach -readonly -nobrowse -mountpoint "$work_dir/mounted" "$dmg"
mounted=true
[[ -L "$work_dir/mounted/Applications" ]] || fail 'The DMG is missing its Applications shortcut.'
verify_app "$work_dir/mounted/AI Usage.app"
spctl --assess --type execute --verbose=2 "$work_dir/mounted/AI Usage.app"
hdiutil detach "$work_dir/mounted"
mounted=false

(cd -- "$work_dir" && shasum -a 256 "$filename" >"$filename.sha256")
mv -- "$dmg" "$artifact"
mv -- "$work_dir/$filename.sha256" "$artifact.sha256"
cp -- "$notary_result" "$artifact.notarization.json"
complete=true
printf 'Release artifact: %s\n' "$artifact"
cat "$artifact.sha256"
