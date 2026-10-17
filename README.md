# Rail Router (Transport Fever 3 mod)

Pick two towns and Rail Router plans a double-track line between them: stations as close to each town centre as it
can get without demolishing anything, stops in the towns along the way, and track that follows the terrain
(**Cheapest**) or runs straight and flat (**Fastest**). It shows the length, bridges, tunnels, grades and a cost
estimate, and draws the route on the map. Building it with one click comes in a later version.

- Mod ID: `pgrace_rail_router`
- Cosmetic: yes. It doesn't affect the simulation, so achievements stay enabled.

Agent and modding notes for all mods live in `../AGENTS.md`.

## Layout

```
mod/pgrace_rail_router/                        # the mod folder TF3 loads
├── mod.json, _metadata/              # modinfo.json, description.html, screenshots
├── tealdef/                          # Teal type definitions (canonical; build.py mirrors them into content/)
└── content/gui/pgrace_rail_router/
    ├── window.res.lua / window.script.tl / window.css.lua   # mod button and window
    ├── survey.tl                     # engine reads: towns, track types, terrain grid
    ├── mapcapture.tl, mapformat.tl   # whole-map capture to the log (dev tool)
    ├── preview.tl                    # the route on the map
    └── planner/                      # pure planner modules (unit-tested)
tools/                                # type check, tests, install, release checks
tests/                                # unit tests for pure modules
```

## Dev loop

```bash
just check      # type-check against the game's API definitions
just test       # unit tests, plus the quick regression routes
just regress    # unit tests plus every regression route (about 30 s)
just verify     # check + test + release-check
just install    # symlink into TF3's staging area (just install-copy to copy)
```

Restart TF3 after code changes. The log is
`~/.local/share/Steam/userdata/*/3493540/local/crash_dump/stdout.txt`; our lines start with `[rail_router]`.

## Map captures and regression routes

A temporary **Capture whole map (probe)** button in the window writes the whole map to the log as `MAP` records
(format: `docs/map-capture-format.md`); **Find route** writes its own input as `CAPTURE` records. Shared maps live in
the kit's `../maps/` folder (`../maps/README.md`); `tests/regression_test.lua` plans fixed routes on them (and
in-game route captures as captured, where the save has changed since its map) and checks invariants (no curve below
the build minimum, nothing on blocked cells, step time and what a step allocates) and figures against a baseline (how
to re-record is at its top). It skips with a message if `../maps/` isn't there. Offline:

```bash
python3 tools/extract_captures.py                     # complete MAP / CAPTURE blocks from stdout.txt into captures/
lua tools/replay.lua --map ../maps/<map> --list       # the map's towns and track types
lua tools/replay.lua --map ../maps/<map> --from Ames --to Bridgeport [--mode fastest] [--stops a,b|none] [out.ppm]
lua tools/replay.lua captures/<capture> [out.ppm]     # replay one in-game Find route
lua tools/compare_capture.lua captures/<map> captures/<capture>   # map rasterised vs the in-game grid
```

`mod/.../mapcapture.tl` + `mapformat.tl`, `tools/maplib.lua` and `tools/extract_captures.py` depend on nothing else
in Rail Router; the kit's template carries copies, so every new mod gets them (`maplib.lua` is the same file).
`tools/replaylib.lua` is the offline planning that `replay.lua` and the regression tests share.

## Releasing

1. Screenshots in `mod/pgrace_rail_router/_metadata/`: `0.png` is the cover, `1.png`… the gallery (1920x1080, ≤8 MB).
2. For an update: `just bump` and commit.
3. `just release` (revision check + verify).
4. Upload from **Mod Hub > My Mods** in TF3.
5. Commit what the upload changed (the first one creates `_metadata/mod.io_fileid.txt`), then `just mark-uploaded`
   and push `main`.
