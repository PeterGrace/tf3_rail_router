#!/usr/bin/env python3
"""Fills the template placeholders: renames paths containing __MODID__ and rewrites text files.

usage: tools/init.py <modId> <display name> <author>
"""
import pathlib
import sys

mod_id, name, author = sys.argv[1:4]
pascal = "".join(part.capitalize() for part in mod_id.split("_") if part)
replacements = {"__MODID__": mod_id, "__MOD_NAME__": name, "__PASCAL__": pascal, "__AUTHOR__": author}
root = pathlib.Path(__file__).resolve().parent.parent
skip = {".git", ".tools"}
text_suffixes = {".lua", ".tl", ".json", ".html", ".md", ".py", ".sh", ".txt", ""}

paths = [p for p in root.rglob("*") if not skip & set(p.relative_to(root).parts)]
for p in paths:
    if p.is_file() and p.suffix in text_suffixes and p.name not in {"init.py", "justfile"}:
        text = p.read_text()
        new = text
        for key, value in replacements.items():
            new = new.replace(key, value)
        if new != text:
            p.write_text(new)
# Deepest paths first, so renaming a folder doesn't invalidate paths below it.
for p in sorted(paths, key=lambda p: len(p.parts), reverse=True):
    if "__MODID__" in p.name:
        p.rename(p.with_name(p.name.replace("__MODID__", mod_id)))
print(f"init: {mod_id} ({name}), records prefixed {pascal}")
