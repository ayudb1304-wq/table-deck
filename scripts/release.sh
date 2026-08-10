#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
build_dir="$repo_root/build/release"
archive_path="$build_dir/Holo.xcarchive"
app_path="$archive_path/Products/Applications/Holo.app"
dmg_root="$build_dir/dmg-root"
dmg_path="${DMG_PATH:-$repo_root/dist/Holo.dmg}"

fail() {
    echo "error: $*" >&2
    exit 1
}

log() {
    echo "==> $*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command '$1' was not found"
}

require_environment() {
    local name="$1"
    [[ -n "${!name:-}" ]] || fail "required environment variable $name is not set"
}

require_environment DEVELOPER_ID_APPLICATION
require_environment DEVELOPMENT_TEAM

notary_arguments=()
if [[ -n "${NOTARYTOOL_KEYCHAIN_PROFILE:-}" ]]; then
    notary_arguments=(--keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE")
else
    require_environment APP_STORE_CONNECT_API_KEY_PATH
    require_environment APP_STORE_CONNECT_KEY_ID
    require_environment APP_STORE_CONNECT_ISSUER_ID
    [[ -r "$APP_STORE_CONNECT_API_KEY_PATH" ]] || \
        fail "APP_STORE_CONNECT_API_KEY_PATH is not a readable file"
    notary_arguments=(
        --key "$APP_STORE_CONNECT_API_KEY_PATH"
        --key-id "$APP_STORE_CONNECT_KEY_ID"
        --issuer "$APP_STORE_CONNECT_ISSUER_ID"
    )
fi

for command_name in xcodegen xcodebuild codesign xcrun hdiutil ditto; do
    require_command "$command_name"
done

if [[ "$dmg_path" != /* ]]; then
    dmg_path="$repo_root/$dmg_path"
fi

case "$dmg_path" in
    "$repo_root"/*.dmg) ;;
    *) fail "DMG_PATH must be a .dmg path inside $repo_root" ;;
esac

case "$dmg_path" in
    *"/../"*|*"/./"*) fail "DMG_PATH must not contain '.' or '..' path components" ;;
esac

mkdir -p "$build_dir" "$(dirname "$dmg_path")"
rm -rf "$archive_path" "$dmg_root"
rm -f "$dmg_path"

cd "$repo_root"

log "Generating Holo.xcodeproj"
xcodegen generate

log "Archiving the Release build"
xcodebuild archive \
    -project Holo.xcodeproj \
    -scheme Holo \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$archive_path" \
    -derivedDataPath "$build_dir/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"

[[ -d "$app_path" ]] || fail "archive did not contain Holo.app at $app_path"

log "Signing embedded code with Developer ID Application"
if [[ -d "$app_path/Contents" ]]; then
    while IFS= read -r -d '' code_path; do
        codesign \
            --force \
            --options runtime \
            --timestamp \
            --sign "$DEVELOPER_ID_APPLICATION" \
            "$code_path"
    done < <(
        find "$app_path/Contents" -depth \
            \( -type f -name '*.dylib' -o -type d -name '*.framework' -o -type d -name '*.xpc' -o -type d -name '*.appex' \) \
            -print0
    )
fi

log "Signing Holo.app with sandbox entitlements and hardened runtime"
codesign \
    --force \
    --options runtime \
    --timestamp \
    --entitlements "$repo_root/Config/Holo.entitlements" \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

log "Creating the distributable DMG"
mkdir -p "$dmg_root"
ditto "$app_path" "$dmg_root/Holo.app"
ln -s /Applications "$dmg_root/Applications"
hdiutil create \
    -volname Holo \
    -srcfolder "$dmg_root" \
    -format UDZO \
    -ov \
    "$dmg_path"

log "Submitting the DMG for notarization"
xcrun notarytool submit "$dmg_path" "${notary_arguments[@]}" --wait

log "Stapling and validating the notarization ticket"
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"

rm -rf "$dmg_root"
log "Release artifact is ready: $dmg_path"
