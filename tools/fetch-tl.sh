#!/usr/bin/env bash
# Downloads the Teal compiler (a single Lua file) used by the check and test tools.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .tools
curl -fsSL https://raw.githubusercontent.com/teal-language/tl/v0.24.8/tl.lua -o .tools/tl.lua
lua -e 'package.path = ".tools/?.lua;" .. package.path; print("tl " .. require("tl").version())'
