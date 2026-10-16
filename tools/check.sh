#!/usr/bin/env bash
# Type-checks every .tl file in the mod against the TF3 API definitions.
set -euo pipefail
cd "$(dirname "$0")/.."
TF3_DIR="${TF3_DIR:-/run/host/var/Fun/SteamLibrary/steamapps/common/Transport Fever 3}"
[ -f .tools/tl.lua ] || tools/fetch-tl.sh
python3 tools/build.py
mapfile -t files < <(find mod -name '*.tl' ! -name '*.d.tl' | sort)
MOD_ID=$(tools/mod_id.sh)
lua tools/check.lua "$TF3_DIR" "$MOD_ID" "${files[@]}"
