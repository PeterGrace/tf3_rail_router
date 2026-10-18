# Rail Router Milestone 3: Build — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** after a clean Check with the game, a Build button builds the planned line: stations, then the track chunk
by chunk joined to them and to each other, with level crossings, stopping at the first failure with Retry.

**Architecture:** the pure parts go in `planner/network.tl` (where a track edge crosses a street curve; a chunk's
network cut at given points and joined to given nodes), unit-tested. The engine side is a new `build.tl`: a state
machine stepped from the window's join, one command in flight at a time, advanced by the commands' callbacks. The
window gets a Build button, progress, and a failure line with Show and Retry. Design: spec "Building (`builder.tl`)",
Milestone 3; probes P9–P11.

**Tech stack:** Teal, the TF3 Lua API (`api.cmd.makeWorldBuildProposalCmd`, `api.engine.util.proposal`), plain-Lua
tests (`just test`).

---

### Task 1: where a track edge crosses a street (pure)

**Files:** `planner/network.tl`, `tealdef/.../planner/network.d.tl`, `tests/network_test.lua`.

- [ ] Add `record Crossing { s : number; u : number; p : Pt3 }` (parameter along the track edge, along the street,
  and the point on the street) and `crossings : function(track : Hermite, street : Hermite) : {Crossing}`: both curves
  sampled into 64 chords each, every pair of chords intersected in plan (proper intersections only), parameters
  interpolated along the chords, sorted by `s`. The point is `hermiteAt(street, u)`.
- [ ] Tests: a straight track square across a straight street crosses once at the right parameters; a track
  parallel to a street never crosses; an S-shaped street crossed twice gives two crossings in order of `s`; a track
  ending short of the street gives none.

### Task 2: a chunk cut at the crossings (pure)

**Files:** as task 1.

- [ ] Add `record Cut { s : number; node : Pt3 }` and `cut : function(net : Network, first : integer, last : integer,
  cuts : {integer : {Cut}}) : Network`: a network of edges `first..last` where an edge with cuts is split
  (`splitHermite`, the parameter rescaled for each later cut) at each cut's `s`, sorted, the pieces meeting at the cut's
  node (its position moved onto the node's, which must be within 1 m). Nodes not cut are the same tables as in `net`
  (so an entity set on one later is seen by both). Its one chunk spans all its edges. Edges keep `kind`, `track`,
  `leg`; `s0`/`s1` are interpolated.
- [ ] Tests: an edge cut once becomes two edges through the cut's node, end points and tangents continuous; two cuts
  give three pieces in order whatever order the cuts are given in; uncut edges and their nodes are passed through
  untouched (same tables).

### Task 3: the build (engine)

**Files:** create `build.tl`, `tealdef/.../build.d.tl`; register it in `tealdef/pgrace_rail_router_def.d.tl`;
`builder.tl` (the station's free ends move here from the probe).

- [ ] `build.start(check) : Build` from a clean `builder.Check` (its plan, settings and network). `build.step(build)`
  is called once per frame from the window's join; it does nothing while a command is in flight (`waiting`),
  otherwise the next action: dry-run and send a station; match its free ends to network nodes (within 1 m; set
  `Pt3.entity`); dry-run a chunk; on street-only collisions (`builder.levelCrossings`, `settings.levelCrossings`),
  split the crossed streets one by one (task 1's crossings for every edge of the chunk; an existing street node within
  3 m is used instead of a split; a split is the engine's `replaceSegment` proposal edited into pieces, its
  `nodeConfigsToAdd` emptied; then each street piece at the new nodes sent again unedited), then the chunk cut at the
  crossings (task 2), dry-run and sent; after a chunk is built, record the entities of its new nodes by place.
- [ ] `build.progress`, `build.failure` (what, the game's messages, where), `build.retry` (clears the failure; the
  next step starts the failed item again). Log each step as `[rail_router] build ...`.

### Task 4: the window

**Files:** `window.script.tl`.

- [ ] Once a check is clean (`failures == 0`), a **Build** button (primary). While building: "Building… {done} of
  {total}"; settings changes are refused while a build runs (the button and Find route do nothing). When done:
  "Built." On a failure: the failed item, its messages, **Show** (camera) and **Retry from here**.

### Task 5: write it down, then the in-game test

- [ ] Spec testing section; AGENTS.md (track joined to existing nodes, level crossings from a script).
- [ ] Remove probes P9–P11's builds once the build works; keep the read-only probes until milestone 5.
- [ ] In-game, on the test map: build Bangor → Imperial Beach (Cheapest): stations, track, the level crossing; run a
  train between two of the stations; the road at the crossing still carries traffic.
