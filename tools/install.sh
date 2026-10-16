#!/usr/bin/env bash
# Installs the mod into TF3's staging area. Symlinks by default; pass --copy to copy instead.
set -euo pipefail
cd "$(dirname "$0")/.."
MOD_ID=$(tools/mod_id.sh)
STAGING="${TF3_STAGING:-$(ls -d "$HOME"/.local/share/Steam/userdata/*/3493540/local/staging_area 2>/dev/null | head -n1)}"
[ -d "$STAGING" ] || { echo "staging_area not found; set TF3_STAGING" >&2; exit 1; }
python3 tools/build.py
rm -rf "${STAGING:?}/$MOD_ID"
if [ "${1:-}" = "--copy" ]; then
	cp -r "mod/$MOD_ID" "$STAGING/$MOD_ID"
	echo "copied to $STAGING/$MOD_ID"
else
	ln -s "$PWD/mod/$MOD_ID" "$STAGING/$MOD_ID"
	echo "symlinked $STAGING/$MOD_ID -> $PWD/mod/$MOD_ID"
fi
