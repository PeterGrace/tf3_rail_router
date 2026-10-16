#!/usr/bin/env python3
"""Pre-upload checks against the TF3 modding guidelines. Exit code 1 if any check fails.

Run tools/build.py first so _content.json is current (tools/check.sh does that).
"""
import json
import pathlib
import re
import struct
import sys

def find_mod() -> pathlib.Path:
    """The single mod folder under mod/ (its name is the modId)."""
    mods = [p for p in (pathlib.Path(__file__).resolve().parent.parent / "mod").iterdir() if p.is_dir()]
    if len(mods) != 1:
        raise SystemExit(f"expected exactly one folder under mod/, found {[p.name for p in mods]}")
    return mods[0]

MOD = find_mod()

# Tags accepted by the game (taken from the TF3 build 40408 binary).
KNOWN_TAGS = {
    "Temperate", "Subarctic", "Tropical", "Map/Savegame", "Savegame", "Locomotive", "Wagon",
    "Multiple Unit", "Plane", "Rail Station", "Road Station", "Airport/Heliport", "Track/Road",
    "Track/Street", "Track", "Road", "Tunnel", "Rail Crossing", "Road Construction",
    "Track Construction", "Building", "Town Building", "Vegetation", "Other Asset", "Script Mod",
    "Resident", "Sound", "Shader", "Campaign", "Localization",
}
TEXT_SUFFIXES = {".lua", ".tl", ".json", ".html", ".md", ".txt"}
BALLAST_SUFFIXES = {".psd", ".xcf", ".fbx", ".blend", ".bak", ".tmp", ".orig", ".swp"}
SEVERITIES = {"None", "Warning", "Critical"}
MAX_IMAGE_BYTES = 8 * 1024 * 1024
MAX_MOD_BYTES = 500 * 1024 * 1024

errors: list[str] = []
warnings: list[str] = []


def image_size(path: pathlib.Path):
    data = path.read_bytes()
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", data[16:24])
    if data[:2] == b"\xff\xd8":  # JPEG: walk segments to the first SOFn marker
        i = 2
        while i + 9 < len(data):
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            length = struct.unpack(">H", data[i + 2:i + 4])[0]
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                h, w = struct.unpack(">HH", data[i + 5:i + 9])
                return w, h
            i += 2 + length
    return None


files = sorted(p for p in MOD.rglob("*"))
total = 0
for p in files:
    rel = p.relative_to(MOD).as_posix()
    if not re.fullmatch(r"[a-z0-9_.@-]+", p.name):
        errors.append(f"name not lowercase/plain: {rel}")
    if p.is_dir():
        if not any(p.iterdir()):
            errors.append(f"empty folder: {rel}")
        continue
    total += p.stat().st_size
    if p.suffix in BALLAST_SUFFIXES or p.name.endswith("~"):
        errors.append(f"source/temp file should not ship: {rel}")
    if p.suffix in TEXT_SUFFIXES:
        raw = p.read_bytes()
        if raw.startswith(b"\xef\xbb\xbf"):
            errors.append(f"UTF-8 BOM: {rel}")
        try:
            raw.decode("utf-8")
        except UnicodeDecodeError:
            errors.append(f"not UTF-8: {rel}")
if total > MAX_MOD_BYTES:
    errors.append(f"mod is {total / 1e6:.1f} MB, over 500 MB")

mod = json.loads((MOD / "mod.json").read_text())
if mod.get("modId") != MOD.name or not re.fullmatch(r"[a-z0-9_]+", mod.get("modId", "")):
    errors.append(f"modId {mod.get('modId')!r} must match folder {MOD.name!r} and use [a-z0-9_]")
if not isinstance(mod.get("revision"), int) or mod["revision"] < 1:
    errors.append("mod.json revision must be an integer >= 1")
for key in ("severityAdd", "severityRemove"):
    if mod.get(key) not in SEVERITIES:
        errors.append(f"mod.json {key} must be one of {sorted(SEVERITIES)}")

info = json.loads((MOD / "_metadata" / "modinfo.json").read_text())
for key, limit in (("name", 32), ("summary", 100)):
    value = info.get(key) or ""
    if not value or len(value) > limit or "\n" in value:
        errors.append(f"modinfo {key} must be 1-{limit} chars without line breaks (is {len(value)})")
if not info.get("authors"):
    errors.append("modinfo authors is empty")
unknown = [t for t in info.get("tags") or [] if t not in KNOWN_TAGS]
if not info.get("tags") or unknown:
    errors.append(f"modinfo tags must be non-empty and from the supported list (unknown: {unknown})")

for lang, loc in (info.get("localization") or {}).items():
    for key, limit in (("name", 32), ("summary", 100)):
        value = loc.get(key) or ""
        if value and (len(value) > limit or "\n" in value):
            errors.append(f"modinfo localization {lang} {key} must be 1-{limit} chars without line breaks (is {len(value)})")

# Translations: every _("...") key in the scripts needs an entry for each language in strings.json. Keys ending in
# "|one", "|few", "|many" or "|other" are plural forms; a language needs only the forms its plural rule uses (as
# rank.pluralCategory), and English needs those too (its other text is its own key).
PLURAL_FORMS = {
    **{lang: {"one", "other"} for lang in ("en", "de", "es", "fr", "it", "nl", "pt_BR")},
    "pl": {"one", "few", "many"},
    "ru": {"one", "few", "many"},
    **{lang: {"other"} for lang in ("ja", "ko", "zh_CN", "zh_TW")},
}
strings_path = MOD / "strings.json"
if strings_path.exists():
    translations = json.loads(strings_path.read_text(encoding="utf-8"))
    used = set()
    for tl in (MOD / "content").rglob("*.tl"):
        if not tl.name.endswith(".d.tl"):
            used |= {m.encode("latin-1", "backslashreplace").decode("unicode_escape") for m in re.findall(r'_\("((?:[^"\\]|\\.)*)"\)', tl.read_text(encoding="utf-8"))}
    plural_keys = {k for k in used if re.search(r"\|(one|few|many|other)$", k)}
    for lang in sorted(set(PLURAL_FORMS) - set(translations)):
        if lang != "en" or plural_keys:  # English needs entries only for plural keys
            warnings.append(f"strings.json: no {lang} translations")
    for lang, table in sorted(translations.items()):
        if not isinstance(table, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in table.items()):
            errors.append(f"strings.json {lang}: must map text to text")
            continue
        if lang not in PLURAL_FORMS:
            errors.append(f"strings.json {lang}: unknown language (add its plural forms to PLURAL_FORMS)")
            continue
        forms = PLURAL_FORMS[lang]
        required = {k for k in plural_keys if k.rsplit("|", 1)[1] in forms}
        if lang != "en":
            required |= used - plural_keys
        missing = sorted(required - table.keys())
        if missing:
            errors.append(f"strings.json {lang}: {len(missing)} untranslated: {missing}")
        unused = sorted(table.keys() - required)
        if unused:
            warnings.append(f"strings.json {lang}: {len(unused)} not needed: {unused}")
        for key in required & table.keys():
            lost = [p for p in re.findall(r"\{\w+\}", key) if p not in table[key]]
            if lost:
                errors.append(f"strings.json {lang}: {key!r} lost placeholder(s) {lost}")

meta = MOD / "_metadata"
images = sorted(p for p in meta.iterdir() if re.fullmatch(r"\d+\.(png|jpg)", p.name))
if not any(p.stem == "0" for p in images):
    warnings.append("no cover image (_metadata/0.png or 0.jpg)")
for p in images:
    size = image_size(p)
    if size != (1920, 1080):
        errors.append(f"{p.name} is {size}, must be 1920x1080")
    if p.stat().st_size > MAX_IMAGE_BYTES:
        errors.append(f"{p.name} is {p.stat().st_size / 1e6:.1f} MB, max 8 MB")

content = MOD / "content"
listed = json.loads((MOD / "_content.json").read_text())["files"]
actual = sorted(p.relative_to(content).as_posix() for p in content.rglob("*") if p.is_file())
if listed != actual:
    errors.append("_content.json is stale; run python3 tools/build.py")

for w in warnings:
    print(f"WARN  {w}")
for e in errors:
    print(f"FAIL  {e}")
print(f"{len(files)} paths, {total / 1e3:.0f} kB, {len(images)} image(s): "
      f"{'OK' if not errors else str(len(errors)) + ' problem(s)'}")
sys.exit(1 if errors else 0)
