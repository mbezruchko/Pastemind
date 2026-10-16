#!/bin/bash
# Builds a release of Pastemind into release/<version>/: the app signed with a Developer ID, notarized and stapled; a
# DMG of it (Pastemind.dmg: the app and a link to Applications), signed, notarized and stapled too; and the appcast Sparkle reads,
# its one item signed with the update key. Publishing is a separate step: it prints the `gh release create` to run.
#
# Once per Mac:
#   - a "Developer ID Application" certificate in the login keychain (Xcode → Settings → Accounts → Manage
#     Certificates → +; the team's Account Holder can make one);
#   - notarytool's credentials, kept in the keychain as a profile:
#       xcrun notarytool store-credentials pastemind-notary --apple-id <Apple ID> --team-id <team ID>
#     (it asks for an app-specific password, made at account.apple.com → Sign-In and Security);
#   - the update key, in the keychain under the account "pastemind" (its public half is SUPublicEDKey in
#     Resources/Info.plist): .build/artifacts/sparkle/Sparkle/bin/generate_keys --account pastemind. Keep a copy
#     somewhere safe (generate_keys --account pastemind -x <file>): without it, installed copies can't be updated.
#
#   scripts/release.sh             the version in Resources/Info.plist (CFBundleShortVersionString; Sparkle compares
#                                  CFBundleVersion, so raise both)
#   scripts/release.sh --dry-run   the same without a Developer ID or notarization (signed as build.sh signs), the
#                                  appcast signed with $SPARKLE_KEY_FILE: checks the DMG and the appcast come out right
set -euo pipefail
cd "$(dirname "$0")/.."
umask 022   # what's in the DMG readable by every user of the Mac, whatever the shell's umask

REPO=mbezruchko/Pastemind
PROFILE=${NOTARY_PROFILE:-pastemind-notary}
PLIST=Resources/Info.plist
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
DRY=false
[[ ${1:-} == --dry-run ]] && DRY=true

fail() { echo "release: $*" >&2; exit 1; }

if $DRY; then
  OUT=release/dry-run-$VERSION
  [[ -n ${SPARKLE_KEY_FILE:-} ]] || fail "--dry-run signs the appcast with \$SPARKLE_KEY_FILE (a throwaway key)"
  KEY=(--ed-key-file "$SPARKLE_KEY_FILE")
  case "$OUT" in release/dry-run-*) rm -rf "$OUT";; esac
else
  OUT=release/$VERSION
  IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' | head -1)
  [[ -n $IDENTITY ]] || fail "no \"Developer ID Application\" certificate in the keychain (see the top of this script)"
  xcrun notarytool history --keychain-profile "$PROFILE" > /dev/null 2>&1 \
    || fail "no notarytool credentials under the profile \"$PROFILE\" (see the top of this script)"
  [[ ! -e $OUT ]] || fail "$OUT is there already: raise the version in $PLIST"
  KEY=(--account pastemind)
fi
mkdir -p "$OUT"
echo "Pastemind $VERSION ($BUILD) into $OUT"

# Signed with the Developer ID (and a secure timestamp: build.sh adds one for such an identity).
if $DRY; then ./build.sh; else SIGN_ID="$IDENTITY" ./build.sh; fi
APP=build.noindex/Pastemind.app
codesign --verify --deep --strict "$APP"

# notarytool waits for Apple's verdict; anything but "Accepted" stops the release, with Apple's log of why.
notarize() {
  local result id status
  result=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json)
  id=$(plutil -extract id raw - <<< "$result")
  status=$(plutil -extract status raw - <<< "$result")
  echo "notarization of $(basename "$1"): $status"
  if [[ $status != Accepted ]]; then
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
    fail "notarization of $1 came back $status"
  fi
}

# The app first, zipped as notarytool takes it, and stapled: it carries its ticket when Sparkle unpacks an update.
if ! $DRY; then
  ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
  notarize "$OUT/notarize.zip"
  rm "$OUT/notarize.zip"
  xcrun stapler staple "$APP"
fi

# The DMG: the app and a link to Applications to drag it onto.
STAGE=$(mktemp -d)
chmod 755 "$STAGE"   # the DMG's top folder (mktemp makes it 700)
ditto "$APP" "$STAGE/Pastemind.app"
ln -s /Applications "$STAGE/Applications"
# Named without its version: the site links to releases/latest/download/Pastemind.dmg.
DMG=$OUT/Pastemind.dmg
hdiutil create -quiet -volname Pastemind -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
case "$STAGE" in /var/folders/*|/tmp/*|/private/*) rm -rf "$STAGE";; esac
if ! $DRY; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  # What Gatekeeper says of each, as a downloaded copy would be judged.
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
  spctl --assess --type execute --verbose "$APP"
fi

# The appcast: this version, its DMG at its release's address, signed with the update key. Sparkle reads it from
# the latest release (SUFeedURL), so every release carries its own.
"$SPARKLE_BIN/generate_appcast" "${KEY[@]}" --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" -o "$OUT/appcast.xml" "$OUT"

echo
echo "Built $DMG and $OUT/appcast.xml."
$DRY && exit 0
echo "To publish (it's public at once):"
echo "  gh release create v$VERSION \"$DMG\" \"$OUT/appcast.xml\" --repo $REPO --title \"Pastemind $VERSION\" --notes \"…\""
