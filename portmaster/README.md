# drgnwrrr

Dragon Warrior minus the walking: the NES game's rules, played from menus and
a map.

## Controls

Buttons go by where they sit on the pad (south is A on an Xbox pad, B on a
Nintendo-style one). The line under the panel shows what they do at the time.

| Button | Panel | Map mode |
|--|--|--|
| D-Pad / Left stick | Move between buttons | Move the cursor |
| South | Press | Go there (again to walk the route) |
| East | Back | Done |
| North / Select | Map mode | Done |
| West | Back to the hero | Back to the hero |
| L1 / R1 | Zoom out / in | Zoom out / in |
| Right stick / triggers | Scroll | Scroll |
| Start | More (Quit is there) | |

Only the king saves (Tantegel throne room). The save is `drgnwrrr.sav` in the
port's folder, in the same format as the CLI's.

## Building

Built with Zig from the drgnwrrr repository, which needs a Dragon Warrior (U)
ROM at build time for the maps:

```sh
zig build portmaster
```

The package is assembled in `zig-out/portmaster`. The binary links SDL3
statically and needs no bundled libraries: it uses SDL's kmsdrm video driver
where the firmware supports it, and the vendor EGL blobs where it doesn't.
