#!/usr/bin/env python3
"""Pulls map captures ("MAP" blocks, docs/map-capture-format.md) and route captures ("CAPTURE" blocks, the window's
probe) out of a TF3 log and writes each complete one to its own file. Truncated blocks (no end record, or record
counts that don't match it) are reported and skipped.

usage: python3 tools/extract_captures.py [log] [--out DIR] [--prefix NAME] [--map-tag TAG] [--capture-tag TAG]

  log            default: ~/.local/share/Steam/userdata/12818001/3493540/local/crash_dump/stdout.txt
  --out DIR      where to write (default: captures/)
  --prefix NAME  file name prefix (default: the log's file name without .txt)
  --map-tag      the tag in front of map records (default "[rail_router] MAP")
  --capture-tag  the tag in front of route capture records (default "[rail_router] CAPTURE")

Files: <prefix>-map-<n>.txt (lines "MAP <record>"), <prefix>-capture-<n>.txt (lines "CAPTURE <record>"), n counting
from 1 in log order. The map's name also says its size and year, e.g. stdout-map-1-20x20km-y1950.txt.
"""
import argparse
import pathlib
import re
import sys

DEFAULT_LOG = pathlib.Path.home() / ".local/share/Steam/userdata/12818001/3493540/local/crash_dump/stdout.txt"
# "[2026-10-17 00:23:03Z - MESSAGE  - Main Thread      - Main           ]  <message>"
LOG_HEADER = re.compile(r"^\[[^\]]*\]\s\s?")
MAP_COUNTED = ("r", "town", "track", "obj", "edge")


def messages(path: pathlib.Path):
    with path.open(encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\r\n")
            yield LOG_HEADER.sub("", line, count=1)


def check_map(lines: list[str]) -> str | None:
    """None if the block is complete, else what's wrong."""
    end = lines[-1].split()
    counts = {}
    for kv in end[2:]:
        k, _, v = kv.partition("=")
        counts[k] = int(v)
    seen = {k: 0 for k in MAP_COUNTED}
    for line in lines:
        kind = line.split(" ", 2)[1] if " " in line else ""
        if kind in seen:
            seen[kind] += 1
    for k in MAP_COUNTED:
        if k in counts and counts[k] != seen[k]:
            return f"{seen[k]} {k} records, the end record says {counts[k]}"
    return None


def check_capture(lines: list[str]) -> str | None:
    begin = lines[0].split()
    try:
        ny = int(begin[6])
    except (IndexError, ValueError):
        return "bad begin line"
    rows = sum(1 for line in lines if line.startswith("CAPTURE row "))
    if rows != ny:
        return f"{rows} rows, expected {ny}"
    return None


def map_name(lines: list[str]) -> str:
    extent, year = None, None
    for line in lines:
        parts = line.split()
        if len(parts) >= 6 and parts[1] == "extent":
            try:
                x0, y0, x1, y1 = (float(p) for p in parts[2:6])
                extent = f"{round((x1 - x0) / 1000)}x{round((y1 - y0) / 1000)}km"
            except ValueError:
                pass
        elif len(parts) >= 4 and parts[1] == "meta" and parts[2] == "gameYear":
            year = f"y{parts[3]}"
    return "-".join(p for p in (extent, year) if p)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log", nargs="?", type=pathlib.Path, default=DEFAULT_LOG)
    ap.add_argument("--out", type=pathlib.Path, default=pathlib.Path("captures"))
    ap.add_argument("--prefix")
    ap.add_argument("--map-tag", default="[rail_router] MAP")
    ap.add_argument("--capture-tag", default="[rail_router] CAPTURE")
    args = ap.parse_args()
    prefix = args.prefix or args.log.stem
    kinds = {
        "map": (args.map_tag + " ", "MAP ", "begin", "end", check_map),
        "capture": (args.capture_tag + " ", "CAPTURE ", "begin", "end", check_capture),
    }
    blocks: dict[str, list[list[str]]] = {k: [] for k in kinds}
    current: dict[str, list[str] | None] = {k: None for k in kinds}
    skipped = 0

    def close(kind: str, why: str):
        nonlocal skipped
        lines = current[kind]
        if lines is not None:
            print(f"skipped a {kind} block of {len(lines)} lines: {why}", file=sys.stderr)
            skipped += 1
        current[kind] = None

    for msg in messages(args.log):
        for kind, (tag, out_tag, begin, end, check) in kinds.items():
            if not msg.startswith(tag):
                continue
            record = out_tag + msg[len(tag):]
            word = msg[len(tag):].split(" ", 1)[0]
            if word == begin:
                close(kind, "truncated (a new block began)")
                current[kind] = [record]
            elif current[kind] is not None:
                current[kind].append(record)
                if word == end:
                    problem = check(current[kind])
                    if problem:
                        close(kind, problem)
                    else:
                        blocks[kind].append(current[kind])
                        current[kind] = None
    for kind in kinds:
        close(kind, "truncated (no end record)")

    args.out.mkdir(parents=True, exist_ok=True)
    for kind, found in blocks.items():
        for n, lines in enumerate(found, 1):
            extra = map_name(lines) if kind == "map" else ""
            name = f"{prefix}-{kind}-{n}" + (f"-{extra}" if extra else "") + ".txt"
            path = args.out / name
            path.write_text("\n".join(lines) + "\n", encoding="utf-8")
            print(f"wrote {path} ({len(lines)} lines)")
    if not any(blocks.values()):
        print("no complete blocks found", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
