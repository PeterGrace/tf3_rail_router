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
    ├── preview.tl                    # the route on the map
    └── planner/                      # pure planner modules (unit-tested)
tools/                                # type check, tests, install, release checks
tests/                                # unit tests for pure modules
```

## Dev loop

```bash
just check      # type-check against the game's API definitions
just test       # unit tests
just verify     # check + test + release-check
just install    # symlink into TF3's staging area (just install-copy to copy)
```

Restart TF3 after code changes. The log is
`~/.local/share/Steam/userdata/*/3493540/local/crash_dump/stdout.txt`; our lines start with `[rail_router]`.

## Releasing

1. Screenshots in `mod/pgrace_rail_router/_metadata/`: `0.png` is the cover, `1.png`… the gallery (1920x1080, ≤8 MB).
2. For an update: `just bump` and commit.
3. `just release` (revision check + verify).
4. Upload from **Mod Hub > My Mods** in TF3.
5. Commit what the upload changed (the first one creates `_metadata/mod.io_fileid.txt`), then `just mark-uploaded`
   and push `main`.
