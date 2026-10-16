# TF3 mod dev tasks. Run `just` to list them.

mod_json := "mod/" + `tools/mod_id.sh 2>/dev/null || echo __MODID__` + "/mod.json"

# List the available recipes
default:
    @just --list

# One-time setup of a fresh copy: `just init pgrace_my_mod "My Mod"`. The modId is your choice ([a-z0-9_], prefix
# it with your name); it can't change after the first upload. The mod.io id is assigned at upload, separately.
init mod_id name author=`git config user.name 2>/dev/null || echo "Your Name"`:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -d mod/__MODID__ ] || { echo "already initialised (no mod/__MODID__ folder)" >&2; exit 1; }
    [[ "{{mod_id}}" =~ ^[a-z0-9_]+$ ]] || { echo "modId must match [a-z0-9_]+" >&2; exit 1; }
    python3 tools/init.py "{{mod_id}}" "{{name}}" "{{author}}"
    [ -d .git ] || git init -q -b main
    tools/fetch-tl.sh
    just verify
    echo "Initialised {{mod_id}}. Next: just install, enable '{{name}}' in TF3, open an industry window."

# Download the Teal compiler used by check/test
fetch-tl:
    tools/fetch-tl.sh

# Type-check all .tl files against the game's API definitions
check:
    tools/check.sh

# Run the unit tests
test:
    lua tools/test.lua

# Pre-upload checks (names, encoding, metadata, images, _content.json)
release-check:
    python3 tools/build.py
    python3 tools/release_check.py

# Type-check, test, and release-check
verify: check test release-check

# Symlink the mod into TF3's staging area (use install-copy if symlinks aren't followed)
install:
    tools/install.sh

# Copy the mod into TF3's staging area
install-copy:
    tools/install.sh --copy

# Show the mod.json revision and the last uploaded revision (rev-N git tags)
revision:
    #!/usr/bin/env bash
    set -euo pipefail
    current=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision"])' {{mod_json}})
    last=$(git tag -l 'rev-*' | sed 's/^rev-//' | sort -n | tail -n1)
    echo "mod.json revision: $current"
    echo "last uploaded:     ${last:-none}"
    if [ -n "$last" ] && [ "$current" -le "$last" ]; then
        echo "status:            needs a bump before the next upload (just bump)"
    else
        echo "status:            ready to upload"
    fi

# Fail unless mod.json's revision is newer than the last uploaded revision
check-revision:
    #!/usr/bin/env bash
    set -euo pipefail
    current=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision"])' {{mod_json}})
    last=$(git tag -l 'rev-*' | sed 's/^rev-//' | sort -n | tail -n1)
    if [ -n "$last" ] && [ "$current" -le "$last" ]; then
        echo "revision $current was already uploaded (tag rev-$last); run: just bump" >&2
        exit 1
    fi
    echo "revision $current is new (last uploaded: ${last:-none})"

# Increase mod.json's revision by one
bump:
    #!/usr/bin/env bash
    set -euo pipefail
    python3 - {{mod_json}} <<'EOF'
    import json, sys
    path = sys.argv[1]
    with open(path) as f:
        data = json.load(f)
    data["revision"] += 1
    with open(path, "w") as f:
        json.dump(data, f, indent=4, ensure_ascii=False)
        f.write("\n")
    print(f"revision -> {data['revision']}")
    EOF
    git diff --stat -- {{mod_json}}

# Everything to run before uploading from Mod Hub: revision check plus verify
release: check-revision verify
    @echo "Ready: upload from Mod Hub > My Mods, then run: just mark-uploaded"

# After a successful upload: tag HEAD as rev-<revision> and push the tag
mark-uploaded:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "$(git status --porcelain)" ]; then
        echo "working tree has uncommitted changes; commit them first (including _metadata/mod.io_fileid.txt)" >&2
        exit 1
    fi
    current=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision"])' {{mod_json}})
    git tag -a "rev-$current" -m "Uploaded revision $current to mod.io"
    git push origin "rev-$current"
    echo "tagged and pushed rev-$current"
