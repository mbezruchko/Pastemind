#!/bin/bash
# Builds build.noindex/Pastemind.app, signed with the hardened runtime.
#   ./build.sh                       signed with the identity in .sign-id (one line, gitignored), else the first
#                                    "Apple Development" identity in the keychain, else ad-hoc. A stable identity keeps
#                                    the Accessibility grant (auto-paste) across rebuilds; ad-hoc builds lose it.
#   SIGN_ID="<identity>" ./build.sh  this identity instead (a "Developer ID Application" one gets a secure timestamp,
#                                    as notarization needs: scripts/release.sh)
# ".noindex" keeps Spotlight from listing the staging copy. Copy it to /Applications to keep it.
set -euo pipefail
cd "$(dirname "$0")"

APP="build.noindex/Pastemind.app"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

scripts/build-llama.sh
swift build -c release --product PastemindApp
swift build -c release --product pastemind-ocr
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PastemindApp" "$APP/Contents/MacOS/Pastemind"
# Text in scans and pictures (Vision), in a process of its own: its models go when it exits.
cp "$BIN_DIR/pastemind-ocr" "$APP/Contents/MacOS/pastemind-ocr"
# Updates (Sparkle), found through the app's rpath, @executable_path/../Frameworks.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# SwiftPM's linker records the deployment target as the SDK it was built with (14.0): AppKit then draws the controls
# as before macOS 26 (switches with round knobs, smaller). The SDK it was really built with, so they're drawn anew.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
xcrun vtool -set-build-version macos 14.0 "$SDK_VERSION" -replace \
  -output "$APP/Contents/MacOS/Pastemind" "$APP/Contents/MacOS/Pastemind"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The icon: Resources/AppIcon.icon, in Icon Composer's format (layers macOS 26 draws as Liquid Glass, in every icon
# style), compiled into Assets.car; for macOS 14 and 15, Resources/AppIcon.icns, flattened from it by
# scripts/make-icon.swift (actool's own stops at 256 pixels). Absolute paths: actool hands the work to an agent that
# outlives it, and resolves relative ones against wherever that agent was first started.
if xcrun --find actool > /dev/null 2>&1; then
  xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon --target-device mac \
    --output-partial-info-plist "$PWD/build.noindex/AppIcon.plist" > /dev/null
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
cp Resources/Acknowledgements.txt "$APP/Contents/Resources/"
cp Resources/highlight.min.js "$APP/Contents/Resources/"   # code's language and colours (see Acknowledgements)

IDENTITY="${SIGN_ID:-$( [[ -f .sign-id ]] && head -1 .sign-id || true )}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)
fi
IDENTITY="${IDENTITY:--}"
TIMESTAMP=--timestamp=none
[[ "$IDENTITY" == "Developer ID Application"* ]] && TIMESTAMP=--timestamp
sign() { codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP "$@"; }
# Inside out: signing a bundle seals what's inside it, signed as it is then. Sparkle's parts as its documentation has
# them (the downloader keeps its entitlements).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP/Contents/MacOS/pastemind-ocr"
sign "$APP"
echo "Built $APP (signed: $IDENTITY)"
