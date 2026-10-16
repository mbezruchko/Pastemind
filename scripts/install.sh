#!/bin/bash
# Installs build.noindex/Pastemind.app into /Applications and starts it.
# The old bundle is removed first, never copied over: `cp -R` onto an existing app rewrites its binary in place (same
# inode), the kernel keeps the old binary's code signature for that file, and the new one is killed at launch
# ("Code Signature Invalid"; `open` then says error -609).
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build.noindex/Pastemind.app
[[ -d "$APP" ]] || { echo "no $APP: run ./build.sh first" >&2; exit 1; }
pkill -x Pastemind 2>/dev/null && sleep 1 || true
rm -rf /Applications/Pastemind.app
ditto "$APP" /Applications/Pastemind.app
codesign --verify --strict /Applications/Pastemind.app
open /Applications/Pastemind.app
echo "Installed and started /Applications/Pastemind.app"
