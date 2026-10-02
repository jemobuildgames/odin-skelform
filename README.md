# odin-skelform

A pure-Odin runtime for **SkelForm** 2D skeletal animation, plus a raylib example that loads and
plays exported `.skf` armatures.

Targets **SkelForm 0.8.0** — see [Version compatibility](#version-compatibility).
The full procedure and type reference lives in **[docs/api.md](docs/api.md)**.

**English** · [中文](README_zh.md)

![The example running with example/skellington.skf](docs/example.png)

## Layout

The repository root **is** the library (`package skelform`); the demo lives next to it. Import it
as `skf` and call it from your own render loop.

| Path | Contents |
| --- | --- |
| `skelform.odin` | Data model + runtime: animation sampling, inheritance, inverse kinematics, physics, mesh deformation |
| `loader.odin` | `.skf` loading: a small ZIP reader (stored + deflate) and `armature.json` mapping |
| `example/main.odin` | raylib demo: window, input, animation loop |
| `example/render.odin` | raylib glue: screen-space construction and textured drawing |
| `example/*.skf` | Demo armatures (`skellington`, `skellina`) |
| `docs/api.md` | API reference: types, procedures, ownership, the raylib adapter contract |
| `docs/` | Screenshots used by this README |

## Version compatibility

This targets **SkelForm 0.8.0** exports.

A `.skf` carries its own format version as the `version` string in `armature.json`, where the
editor writes its own package version. **This runtime does not read that field**: parsing is
version-agnostic, so a file from a newer editor loads with unrecognised keys dropped rather than
failing. The two armatures shipped in `example/` are **0.7.0** exports and load unchanged.

* Exports from before **0.6** are not handled. The editor upgrades those itself when opening
  (`src/backwards_compat.rs` covers 0.2 → 0.5), so runtimes only ever see current-version JSON.
  Re-export old files from the editor instead of feeding them to a runtime.
* Need strict checking? Read `version` out of `armature.json` yourself — `skf_find_entry` will hand
  you the entry.

## Requirements

* Odin `dev-2026-09-nightly` or newer (developed on `dev-2026-09-nightly:a2fb372`).
* The runtime has no C dependency and no third-party Odin dependency: only `core:` packages
  (`core:encoding/json`, `core:compress/zlib`, `core:mem`, …).
* The example additionally needs `vendor:raylib`, which ships with the Odin compiler.

## Using the runtime

Four calls per frame. Everything below is what `example/main.odin` does.

```odin
import skf "path/to/odin-skelform"

// 1) Load the archive exported by the SkelForm editor. Do this once, not per frame.
archive, ok := skf.skf_load("hero.skf")
if !ok {
	return
}
defer skf.skf_destroy(&archive)

armature := &archive.armature

// 2) Sample an animation into the bones. One entry in each slice per playing animation --
//    the runtime supports several animations at once, the example plays just one.
animations := []skf.Animation{armature.animations[0]}
frames := []u32{skf.time_frame(elapsed_seconds, &animations[0], false, true)}
smooth_frames := []u32{20}
skf.animate(
	&armature.bones,
	&armature.inverse_kinematics,
	&armature.visuals,
	animations,
	frames,
	smooth_frames,
)

// 3) Build the skeleton: constructed bone transforms plus deformed meshes.
skf.construct(armature)

// 4) Draw `armature.constructed_bones` and `armature.visuals` with your own renderer.
```

Step 4 is the only part the library deliberately does not provide. `example/render.odin` is the
raylib version: it flips the armature into raylib's Y-down screen space and emits every bone —
mesh or sprite quad — as rlgl triangles. Copy it into a project and adapt it, or call it directly
(see [Running the example](#running-the-example)).

Two things to know before drawing:

* The atlas PNGs come back as raw bytes in `archive.atlases`, in the same order as
  `armature.atlases`; `Texture.atlas_idx` selects which atlas a bone samples. Upload them to
  textures yourself.
* Textures are looked up per **style** (costume). Pass only the worn styles to the draw step; a
  style that has no entry for a texture, or only a 1×1 one, hides that part. `skf.active_styles`
  returns the armature's own selection.

## Running the example

```sh
odin run example                        # windowed, uses example/skellington.skf
odin run example -- example/skellina.skf
```

Or build it once and run the exe — it also finds the armatures relative to its own directory, so
`build/example.exe` works from anywhere:

```sh
odin build example -out:build/example.exe
./build/example.exe
```

The window is 900×700 and the HUD lists the live controls.

![The same demo with example/skellina.skf](docs/example_skellina.png)

| Key | Action |
| --- | --- |
| `A` / `D` | Walk left / right. The facing direction follows the last horizontal key. |
| `W` / `S` | Move up / down |
| `SPACE` | Cycle to the next animation |
| `1` … `9` | Wear that single costume (style) |
| `0` | Go back to the armature's active costume set |
| `B` | Toggle the bone overlay: a line per bone-to-parent link, a dot per joint, hidden bones in red |
| `F12` | Write a screenshot — only when `-screenshot file.png` was also given |

`B` toggles the bone overlay, the quickest way to see what `construct` actually produced — here on
the `Stand` and `Run` animations:

![Standing, with the bone overlay on](docs/bones_stand.png)

![Running, with the bone overlay on](docs/bones_run.png)

Every mode the keys reach is also startable from the command line:

| Flag | Meaning |
| --- | --- |
| `<file>.skf` | Armature to load (positional, defaults to `example/skellington.skf`) |
| `-frames N` | Quit after N frames — makes the example scriptable |
| `-hidden` | Create the window hidden (no desktop flash); pair with `-frames` |
| `-stats` | Read the last frame and print how many pixels differ from the clear colour |
| `-static` | Freeze the animation on frame 0 |
| `-bones` | Start with the bone overlay on |
| `-left` | Start facing left instead of right |
| `-screenshot file.png` | Where `F12` writes; without it no capture happens at all |

```sh
odin run example -- -frames 120 -hidden -stats          # headless smoke test
odin run example -- -static -bones                      # inspect the rig
odin run example -- -left                               # check the mirrored facing
```

`-stats` turns the example into a render check that needs no window:

```text
skelform: loaded example/skellington.skf: 61 bones, 4 animations, 21 visuals, 5 IK families, 1 atlases, 4 styles
skelform: 59561 / 630000 pixels differ from the clear color (9.5%)
skelform: ok, drew 30 frames, 61 constructed bones
```

A run that loads but draws nothing reports `0 / 630000 ... (0.0%)`, so a non-zero count is the
pass condition.

## API reference

Every type with its fields, every procedure with its signature, the `Keyframe.element` strings the
runtime recognises, the ownership table and the raylib adapter contract are in
**[docs/api.md](docs/api.md)**. The four things worth memorising:

1. Per frame it is `animate` → `construct` → draw `constructed_bones` and `visuals`. Never draw
   `armature.bones`.
2. Reference ids are `i32` and `-1` means "none"; `Bone.id` is dense from 0 and doubles as its own
   index into `bones`.
3. `active_styles` and `inverse_kinematics` return freshly allocated values the caller must
   `delete()`.
4. An `Armature` **borrows** its strings from the `SKF` that produced it — keep the `SKF` alive for
   as long as you draw from its armature. `armature_destroy` frees arrays only, which is what makes
   a hand-built armature safe to destroy too.

## The `.skf` format

A `.skf` file is a plain ZIP archive:

```text
armature.json   runtime data (mapped onto `Armature`)
atlas0.png ...  one PNG per entry of `armature.atlases`
editor.json, thumbnail.png, readme.md   editor-only extras (ignored)
```

`loader.odin` implements the ZIP central-directory reader itself (stored and deflate entries,
handled through `core:compress/zlib`) and maps the JSON by hand, so absent keys fall back to the
defaults the exporter expects: missing tints become `(1, 1, 1, 1)`, missing scalars `0`, missing
vectors `(0, 0)`, `Keyframe.handle_preset` `.Linear`. Older editor versions wrote the IK family id
as `"id"`; both `"id"` and `"family_id"` are accepted.

Note that `Style.active` is *not* in `armature.json` — the editor keeps it in `editor.json`. An
exported `.skf` therefore reports no style as active, and `active_styles` falls back to the style
named `"Default"`, or to the last style.

MIT licensed — see [LICENSE](LICENSE).
