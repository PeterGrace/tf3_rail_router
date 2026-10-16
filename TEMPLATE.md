# TF3 mod template

Copy this folder, then initialise it:

```bash
cp -r template my_new_mod
cd my_new_mod
just init pgrace_my_new_mod "My New Mod"
```

`init` fills in the placeholders (`pgrace_rail_router`, `Rail Router`, `PgraceRailRouter`, `Peter Grace`) and renames the
`pgrace_rail_router` paths. It also runs `git init`, fetches Teal and runs `just verify`. Delete this file afterwards.

The **modId** is yours to choose: `[a-z0-9_]`, prefixed with your name. It must be unique across all mods, and can't
change after the first upload. The mod.io id is separate; the first upload assigns it automatically.

What you get is a working mod. It adds a card to every industry window saying "Hello, <industry name>!". Replace
`util.tl` and the script with real features, and keep pure logic in modules the unit tests can load.

See `../AGENTS.md` for everything learned so far about TF3 modding.
