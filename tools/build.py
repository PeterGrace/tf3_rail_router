#!/usr/bin/env python3
"""Prepares the mod folder: mirrors tealdef/*.d.tl into content/ (as official mods ship them) and writes _content.json."""
import json
import pathlib
import shutil

def find_mod() -> pathlib.Path:
    """The single mod folder under mod/ (its name is the modId)."""
    mods = [p for p in (pathlib.Path(__file__).resolve().parent.parent / "mod").iterdir() if p.is_dir()]
    if len(mods) != 1:
        raise SystemExit(f"expected exactly one folder under mod/, found {[p.name for p in mods]}")
    return mods[0]

mod = find_mod()
tealdef = mod / "tealdef"
content = mod / "content"

for src in tealdef.rglob("*.d.tl"):
    rel = src.relative_to(tealdef)
    if len(rel.parts) > 1:  # skip the top-level <modId>_def.d.tl registry
        dst = content / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)

files = sorted(p.relative_to(content).as_posix() for p in content.rglob("*") if p.is_file())
(mod / "_content.json").write_text(json.dumps({"archives": None, "files": files}, indent=4) + "\n")
print(f"build: {len(files)} content files")
