#!/usr/bin/env bash
# Prints the modId: the name of the single folder under mod/.
set -euo pipefail
cd "$(dirname "$0")/.."
mods=(mod/*/)
if [ ! -d "${mods[0]}" ] || [ "${#mods[@]}" -ne 1 ]; then
	echo "expected exactly one folder under mod/" >&2
	exit 1
fi
basename "${mods[0]}"
