# Formula reference page

Source for the Dragon Warrior formula reference: each mechanic as a plain rule, the 6502
routine, and a Zig port. The Zig blocks on the page *are* `tools/romcheck/reference.zig`.

| File | What it is |
| --- | --- |
| `template.html` | The page. Edit this. |
| `tables.zig` | Enemy and zone tables, spliced into the page at `/*TABLES*/`. |
| `data.json` | Enemy rows for the bestiary, spliced in at `/*DATA*/`. |
| `build.mjs` | Writes `dw-reference.html` and regenerates `tools/romcheck/reference.zig`. |
| `smoke.cjs` | Optional: loads the built page in jsdom and checks it renders. |

```sh
node docs/reference/build.mjs              # page + reference.zig
zig test tools/romcheck/reference.zig      # the page's Zig tests
zig build romcheck                         # compare the ports with the ROM

cd docs/reference && npm install && node smoke.cjs   # optional
```

`dw-reference.html` is a single self-contained file you can open locally. The published copy
is at https://claude.ai/artifact/1PtmYnrTCMFSjq2JrbyCUS.
