# Map capture format, version 1

A map capture is a plain-text snapshot of a whole Transport Fever 3 map (terrain, towns, buildings and other
constructions, streets and track) written to the game log by `mapcapture.tl` (with `mapformat.tl`, under
`content/gui/pgrace_rail_router/`). Tools rebuild the map from it offline, without the game: `tools/maplib.lua` loads it, and
can rasterise any box of it into a grid (Rail Router's `tools/replay.lua --map` plans routes on it that way). The
format depends on no particular mod, so maps are shared between mods: they live in the kit's `maps/` folder
(`../maps/README.md`), and tests read them from there.

## Getting a file

1. In-game, the capture writes one log line per record, each starting with a tag (default `[rail_router] MAP`) and a
   space:
   `[2026-10-17 00:23:03Z - MESSAGE  - Main Thread - Main ]  [rail_router] MAP town 60458 -6492.00 ...`
   The window's temporary **Capture whole map (probe)** button runs it (`window.script.tl`, PROBE code).
2. `python3 tools/extract_captures.py [log] [--out DIR] [--map-tag TAG]` keeps each complete block (from `begin` to a
   matching `end`), strips the log header and the tag, and writes it with every line starting `MAP `. Blocks that
   were cut short (no `end`, or record counts that don't match it) are skipped.

A map file is therefore a text file (UTF-8, `\n` line ends) of lines `MAP <record> <fields...>`. Readers ignore lines
that don't start with `MAP `.

## Conventions

- **Coordinates** are world metres, measured from the map's centre (as `api.engine.terrain` uses them), x east, y
  north, z up. Numbers are written with two decimals (`%.2f`) unless stated otherwise.
- **Fields** are separated by one space. A field that may contain spaces (a name, a free-form value) is always the
  last one on its line and runs to the line's end. Other text fields have whitespace replaced by `_`.
- `-` stands for "none" in any field; `-1` for "no entity" in entity fields.
- Entity ids are the game's entity numbers in that save; they only mean something within one file.
- Unknown record names must be ignored by readers (later versions may add records). A reader must refuse a `begin`
  with a version newer than it knows.

## Records, in the order they are written

| Record | Fields | Meaning |
|---|---|---|
| `begin` | `<version>` | Always first. This document describes version `1`. |
| `meta` | `<key> <value...>` | One per key. Written: `captured` (real-world UTC time, ISO 8601, if `os.date` is available), `gameYear`, `gameDate` (YYYY-MM-DD), `extentCheck` (see below), plus any the caller adds (Rail Router: `mod`). |
| `extent` | `<x0> <y0> <x1> <y1> <source>` | The map's extent: min and max corners. `source`: `bbox` (`api.engine.terrain.getBoundingBox()`), `tiles` (the TERRAIN component's `size` × 256 m, centred on 0) or `probe` (`isValidCoordinate` probed outward from the centre to 1 m). |
| `terrain` | `<key> <value...>` | Settings of the TERRAIN component, as far as they are readable: `component` (where it was found: `world`, `entity <id>` or `none`), `size` (tiles x y, 256 m each), `baseResolution` (x y z), `waterLevel`, `offsetZ`, `baseLevels`, `highLevels`; and from the terrain API `apiBaseResolution`, `apiHighResolution`. |
| `grid` | `<spacing> <x0> <y0> <nx> <ny>` | The terrain grid: `nx` × `ny` points, `spacing` metres apart (25 in version 1), point (1, 1) at (x0, y0) (the extent's min corner), column ix at x0 + (ix − 1) · spacing, row iy at y0 + (iy − 1) · spacing. Rows run south to north (increasing y), columns west to east. |
| `town` | `<id> <cx> <cy> <x0> <y0> <x1> <y1> <name...>` | Every town: its centre (the middle of its bounding box, as Rail Router uses it) and its bounding box. |
| `track` | `<key>=<value>;<key>=<value>...` | A track type as the caller passes it, if any (Rail Router: `survey.trackTypes()`: `name`, `label`, `cost`, `speed` (m/s), `maxSlopeBuild`, `minCurveRadiusBuild`, `trackDistance`, `yearFrom`, `yearTo` (0 = no limit), `catenary` (absent if none), `catenaryYearFrom`). Keys sorted. Values are numbers, `true`/`false` or text; `;` in values is replaced by a space. |
| `r` | `<iy> <ix> <heights> <flags>` | Terrain points ix, ix + 1, ... of row iy (at most 128 per line, so a row takes several lines). Details below. |
| `obj` | `<id> <kind> <boxSource> <x0> <y0> <z0> <x1> <y1> <z1> <construction> <town> <file>` | Every construction and every town building. Details below. |
| `edge` | `<id> <kind> <type> <node0> <node1> <p0x> <p0y> <p0z> <p1x> <p1y> <p1z> <t0x> <t0y> <t0z> <t1x> <t1y> <t1z> <template>` | Every street and track edge. Details below. |
| `end` | `<name>=<count>...` | Always last: `r`, `town`, `track`, `obj` and `edge` are the numbers of those records written; `failures` counts reads that threw (and were skipped). A file without `end`, or whose record counts differ from it, is truncated. |

### Terrain lines (`r`)

- **Heights** (`getHeightAt`, so terrain alignments are included) are whole decimetres, comma separated: the first
  absolute, each following one the difference from the one before. `100,3,-4` is 10.0 m, 10.3 m, 9.9 m. Points off
  the map hold the height of the nearest point on it (as `getHeightAt` returns).
- **Flags** are one letter per point, run-length encoded as letter + count: `L` on the map and dry, `W` on the map
  and on water (`isOnWater`), `X` off the map (`isValidCoordinate` false). `L60W8L60` is 60 dry points, 8 water
  points, 60 dry points.
- The flags of a line cover exactly as many points as its heights.

### Objects (`obj`)

- `kind`: `townbuilding` for TOWN_BUILDING entities. For CONSTRUCTION entities it's guessed from the construction's
  `fileName`: `station`, `industry`, `depot` or `building` if the name contains that word (`industr` for industry),
  else `other`. The file name is kept in `file`, so a reader can classify differently.
- `boxSource`: `own` (the entity's BOUNDING_VOLUME), `con` (no box of its own: its TOWN_BUILDING construction's box)
  or `none` (no box at all; the six box fields are then `-`).
- The box is the world-space bounding box (min corner, max corner).
- `construction` and `town`: for town buildings, the TOWN_BUILDING component's construction and town entities;
  otherwise `-1`.
- A town building and its construction are both listed (as the game has both); they usually share a box.

### Edges (`edge`)

- `kind`: `s` for a street (the edge has BASE_EDGE_STREET), `t` for track.
- `type`: `n` normal, `b` bridge, `u` tunnel, `?` unknown (BASE_EDGE.type).
- `node0`, `node1`: the edge's node entities.
- `p0`, `p1`, `t0`, `t1`: the cubic Hermite curve from BASE_EDGE `position0`, `position1`, `tangent0` and
  `tangent1`: the point at t ∈ [0, 1] is h00·p0 + h10·t0 + h01·p1 + h11·t1 (h00 = 2t³ − 3t² + 1, h10 = t³ − 2t² + t,
  h01 = −2t³ + 3t², h11 = t³ − t²). Where the curve couldn't be read, p0 and p1 are the nodes' BASE_NODE positions
  and the tangent fields are `- - -`: draw a straight line.
- `template`: BASE_EDGE `roadTemplate`, or `-` if unreadable.

## Size and time

Measured (Rail Router, in-game): a 4.6 × 13.8 km test map with 5 towns and 1,160 objects is 420 KB and took 0.8 s; a
16 × 16 km save with 54 towns, 38,746 objects and 9,784 edges is 7.2 MB and took 8.4 s (2.6 s of work over 401
frames at a 6 ms budget, the slowest single task 23 ms). In that file the terrain is 1.3 MB (3,936 `r` lines), the
objects 4.2 MB (about 108 bytes each) and the edges 1.7 MB (about 177 bytes each).

So a map is about 0.5 MB per 100 km² of terrain (more in hills: a height difference takes 2–4 characters), plus
about 110 bytes per object and 180 per edge, and roughly half as much again in the log, where every line also
carries the log's own header (about 85 bytes). A 20 × 20 km map with 30,000 objects and 10,000 edges would be about
7 MB.

## Rasterising (optional; Rail Router's rules)

`maplib.rasterise(map, x0, y0, cell, nx, ny)` builds the grid Rail Router's `survey.tl` builds in-game, from the
file. Other mods can use it, or read the records their own way:

- A cell centre whose nearest grid point is `X` is blocked, height 0, dry (survey: `isValidCoordinate` false).
- Otherwise its height is interpolated bilinearly between the four grid points round it, and it is water if its
  nearest grid point is `W` (survey: `getHeightAt` and `isOnWater` at the cell centre).
- Every object with a box blocks the cells nearest the corners of its box grown by 30 m (`opts.buffer`), and all
  cells between (Rail Router's `planner/area.tl` `markBox`).
- Every edge except tunnels marks the cells along its curve (sampled at most half a cell apart), or along its
  straight line, as road (streets) or track (`area.markCurve`, `area.markLine`).

The differences from in-game come from the 25 m grid (heights, water and the map's edge are resolved to 25 m, not
read at the exact centre, where the game's terrain has a 4 m base and a 1 m high resolution) and from survey only
looking up objects in its own area's tiles. Rail Router's `tools/compare_capture.lua` measured them against two
in-game route captures (100 m cells): blocked, road and track cells all the same; water 3 and 13 cells apart (the
test map's on its lake shore); heights 0.01 m and 0.19 m apart on average, at most 2.6 m and 6.1 m.

## Versioning

Additions that old readers can skip (new `meta` or `terrain` keys, new record names, new keys in `end`) keep the
version. Anything that changes the meaning or layout of an existing record's fields raises it.
