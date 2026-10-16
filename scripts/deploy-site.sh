#!/bin/bash
# Publishes site/ to Cloudflare Pages: the page, its media, fonts and _headers, without the design notes (*.md) or
# Finder's .DS_Store. The first run creates the project.
#
#   npx wrangler@4.146.0 login       once per Mac (opens the browser)
#   scripts/deploy-site.sh           to https://<project>.pages.dev (PAGES_PROJECT, default "pastemind")
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT=${PAGES_PROJECT:-pastemind}
WRANGLER=(npx --yes wrangler@4.146.0)

STAGE=$(mktemp -d)
trap 'case "$STAGE" in /var/folders/*|/tmp/*|/private/*) rm -rf "$STAGE";; esac' EXIT
rsync -a --exclude '.DS_Store' --exclude '*.md' site/ "$STAGE/"

if ! "${WRANGLER[@]}" pages project list 2>/dev/null | grep -qw "$PROJECT"; then
  "${WRANGLER[@]}" pages project create "$PROJECT" --production-branch main
fi
"${WRANGLER[@]}" pages deploy "$STAGE" --project-name "$PROJECT" --branch main --commit-dirty=true
