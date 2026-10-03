# skelform API reference

Machine-oriented reference for the `skelform` Odin package. Everything here is transcribed from
`skelform.odin` and `loader.odin`; when the two disagree, the source wins.

```odin
import skf "odin-skelform"   // the repository root is the package
```

* Package name: `skelform`, imported by convention as `skf`.
* Files: `skelform.odin` (data model + runtime), `loader.odin` (`.skf` parsing).
* Dependencies: `core:mem`, `core:math`, `core:slice`, `core:strings`, `core:encoding/json`,
  `core:compress/zlib`, `core:os`, `core:filepath`. No C dependency.
* Data format: SkelForm `.skf` exports. See [Version](#version).

---

## Conventions you must know before calling anything

| Topic | Rule |
| --- | --- |
| Angles | Radians everywhere. `Bone.rot`, `Keyframe.value` for `"Rotation"`, `Visuals.pivot_rot`. |
| Coordinate space | Armature space is **Y up**, origin at the armature root. Screen space in the example is Y down; the runtime itself never converts. |
| Bone ids | `Bone.id` is `u32` and dense from 0, so it can be used as an array index into `bones`. Parent/visuals/physics/ik references are `i32` and **`-1` means "none"**. |
| Frames | `u32`, starting at 0, per animation. The last keyframe's `frame` is the animation length. |
| Colours | `Tint` channels are `f32` in `0..1`, not 0..255. |
| Allocation | Every allocating procedure uses the ambient `context.allocator` (default `context.allocator = mem.GlobalAllocator` unless you set it). Wrap a frame in `mem.Scope` to keep runtime scratch off the heap. |
| Failure mode | Malformed input never panics: an out-of-range id or missing array element makes the runtime **skip that element**. Sites are tagged `NOTE(panic-safety):` in the source. Under `-no-bounds-check` those become silent out-of-bounds reads, so validate `.skf` files in such builds. |

### The one call order that matters

```odin
skf.animate(&armature.bones, &armature.inverse_kinematics, &armature.visuals, anims, frames, smooth_frames)
skf.construct(armature)
// then read armature.constructed_bones and armature.visuals[i].vertices
```

`animate` writes the *authored* bones; `construct` derives `constructed_bones` and deforms the
meshes. Never draw `armature.bones`; draw `armature.constructed_bones`.

---

## Types

### Math

```odin
Vec2   :: struct { x, y: f32 }
Tint   :: struct { r, g, b, a: f32 }          // 0..1 per channel
Vertex :: struct { pos, uv, init_pos: Vec2 }  // init_pos is the bind-pose position
```

### Enums

```odin
HandlePreset :: enum i32 { Linear, SineIn, SineOut, SineInOut, None, Custom }
JointConstraint :: enum i32 { None, Clockwise, CounterClockwise }
InverseKinematicsMode :: enum i32 { FABRIK, Arc }
AnimElement :: enum i32 { PositionX, PositionY, Rotation, ScaleX, ScaleY, Zindex, Texture, IkConstraint }
```

`AnimElement` is documentation only and is **not** the authoritative list, because the runtime
compares `Keyframe.element` as a string. The strings it actually recognises:

| `Keyframe.element` | Drives |
| --- | --- |
| `"PositionX"`, `"PositionY"` | `Bone.pos.x`, `Bone.pos.y` |
| `"Rotation"` | `Bone.rot` |
| `"ScaleX"`, `"ScaleY"` | `Bone.scale.x`, `Bone.scale.y` |
| `"Hidden"` | `Bone.hidden`, set to `value == 1.0` exactly |
| `"TintR"`, `"TintG"`, `"TintB"`, `"TintA"` | `Visuals.tint` of the bone's visuals |
| `"Tex"` | `Visuals.tex` (uses `Keyframe.value_str`) |
| `"IkConstraint"` | `InverseKinematics.constraint` (uses `value_str`) |
| `"MimicTarget"` | `InverseKinematics.mimic_target` |
| `"Zindex"` | `Visuals.zindex` |

Any other string is ignored and does not mark the element as animated.

### Data model

Field order is significant: it matches the JSON keys of `armature.json`.

```odin
Bone :: struct {
	id:           u32,
	name:         string,
	parent_id:    i32,   // -1 = root
	rot:          f32,
	scale:        Vec2,
	pos:          Vec2,
	hidden:       bool,
	ik_family_id: i32,   // -1 = none; >=0 indexes Armature.inverse_kinematics
	visuals_id:   i32,   // -1 = none; >=0 indexes Armature.visuals
	physics_id:   i32,   // -1 = none; >=0 indexes Armature.physics
	init_rot:     f32,   // bind pose, used by reset_inheritance and animate's
	init_scale:   Vec2,  // easing-back of untouched elements
	init_pos:     Vec2,
	init_hidden:  bool,
}

Physics :: struct {      // the *state* of one physics chain, indexed by Bone.physics_id
	global_pos:        Vec2,
	pos_damping:       f32,   // 0 disables; higher = slower follow
	pos_ratio:         f32,   // <0 damps Y only, >0 damps X only
	global_rot:        f32,
	global_orbit:      f32,
	global_orbit_diff: f32,
	global_orbit_vel:  f32,
	rot_damping:       f32,
	rot_bounce:        f32,   // 0..1
	rot_vel:           f32,
	sway:              f32,
	global_scale:      Vec2,
	scale_damping:     f32,
	scale_ratio:       f32,
}

Visuals :: struct {
	tex:         string,           // texture name to look up in the active styles
	tint:        Tint,
	vertices:    [dynamic]Vertex,  // deformed in place by construct_verts
	indices:     [dynamic]u32,     // triangle list; len must be a multiple of 3
	binds:       [dynamic]BoneBind,
	zindex:      i32,              // higher draws first (painted back to front)
	pivot_pos:   Vec2,             // texture-space fraction of tex.size, Y up
	pivot_rot:   f32,
	pivot_scale: Vec2,
	init_tex:    string,
	init_zindex: i32,
	init_tint:   Tint,
}

BoneBind :: struct {
	bone_id: i32,
	is_path: bool,          // true = path bind (order of `verts` follows the bone chain)
	verts:   [dynamic]BoneBindVert,
}

BoneBindVert :: struct {
	id:     u32,   // index into Visuals.vertices
	weight: f32,   // 0..1
}

Keyframe :: struct {
	frame:         u32,
	bone_id:       u32,
	element:       string,   // see the table above
	value:         f32,
	next_kf:       i32,      // -1 when unset; filled in by the loader
	value_str:     string,   // for "Tex" / "IkConstraint"
	start_handle:  Vec2,     // bezier control points, normalised 0..1
	end_handle:    Vec2,
	handle_preset: HandlePreset,
	label_top:     f32,
}

Animation :: struct {
	name:      string,
	fps:       u32,
	keyframes: [dynamic]Keyframe,
}

InverseKinematics :: struct {
	family_id:         i32,
	constraint:        string,   // "None" | "Clockwise" | "CounterClockwise"
	mode:              string,   // "FABRIK" | "Arc"
	target_id:         i32,      // -1 = family disabled
	bone_ids:          [dynamic]u32,  // [0] is the chain root
	mimic_target:      bool,
	init_constraint:   string,   // bind-pose copies, used by animate's reset
	init_mode:         string,
	init_mimic_target: bool,
}

Texture :: struct {
	offset:    Vec2,   // px into the atlas
	size:      Vec2,   // px; a 1x1 rect means "this costume hides this part"
	name:      string, // matches Visuals.tex / Bone name conventions
	atlas_idx: u32,    // index into Armature.atlases and SKF.atlases
}

Style :: struct {     // one costume
	id:       u32,
	name:     string,
	active:   bool,   // NOT present in a game export; see active_styles
	textures: [dynamic]Texture,
}

TexAtlas :: struct {
	filename: string,  // entry name inside the .skf ZIP, e.g. "atlas0.png"
	size:     Vec2,
}

Armature :: struct {
	baked_ik:           bool,   // true = skip the IK pass in construct
	bones:              [dynamic]Bone,     // authored state, written by animate
	constructed_bones:  [dynamic]Bone,     // derived, what you draw
	animations:         [dynamic]Animation,
	textures:           [dynamic]Texture,  // all textures of the armature
	styles:             [dynamic]Style,
	atlases:            [dynamic]TexAtlas,
	inverse_kinematics: [dynamic]InverseKinematics,
	visuals:            [dynamic]Visuals,
	physics:            [dynamic]Physics,
}
```

### Loaded archive

```odin
SKF :: struct {
	armature: Armature,
	atlases:  [dynamic][]u8,  // raw PNG bytes, parallel to armature.atlases
	root:     json.Value,     // opaque: owns every string the armature borrows
	has_root: bool,
}
```

---

## Loading

```odin
skf_load             :: proc(path: string)                    -> (skf: SKF,  ok: bool)
skf_load_from_memory :: proc(data: []u8)                      -> (skf: SKF,  ok: bool)
skf_destroy          :: proc(skf: ^SKF)
skf_find_entry       :: proc(data: []u8, name: string)        -> (out: []u8, ok: bool)
armature_parse_json  :: proc(data: []u8) -> (armature: Armature, root: json.Value, ok: bool)
```

| Proc | Notes |
| --- | --- |
| `skf_load` | Reads the file with `context.allocator`, then delegates. `ok == false` on a missing file, a non-ZIP buffer, a missing `armature.json`, or a JSON root that is not an object. |
| `skf_load_from_memory` | Does **not** take ownership of `data`; atlas bytes are copied out. Safe to free the buffer afterwards. |
| `skf_destroy` | Frees the armature arrays, the atlas buffers and the JSON tree. Must run under the same allocator that loaded. Sets `skf^ = {}`. |
| `skf_find_entry` | Returns a freshly allocated copy of one ZIP entry (`"editor.json"`, `"thumbnail.png"`, …). Debug helper. |
| `armature_parse_json` | Parses `armature.json` alone. The armature's strings are owned by `root`: call `armature_destroy` first, then `json.destroy_value(root)`. |

Missing JSON keys get these defaults: tint `(1,1,1,1)`, scalars `0`, vectors `(0,0)`, bools `false`,
strings `""`, `handle_preset` `.Linear`. Both `"family_id"` and the older `"id"` are accepted for an
IK family.

---

## Per-frame runtime

```odin
animate :: proc(
	bones:              ^[dynamic]Bone,
	inverse_kinematics: ^[dynamic]InverseKinematics,
	visuals:            ^[dynamic]Visuals,
	anims:              []Animation,
	frames:             []u32,
	smooth_frames:      []u32,
)

construct :: proc(armature: ^Armature)
```

`animate` takes the three slices it writes **separately from** the `Armature`, and processes
`min(len(anims), len(frames), len(smooth_frames))` animations, index-aligned: `anims[i]` is played
at `frames[i]` with `smooth_frames[i]` of easing. Returns immediately if `frames` or `smooth_frames`
is empty.

`smooth_frames[a]` is the interpolation smoothing window used while applying animation `a`'s
keyframes. Elements the playing animations do **not** touch are eased back to their `init_*` value
using `smooth_frames[0]` and `frames[0]`. The reset pass is indexed at `[0]` only, so keep the
slice at least as long as the animation count and give `[0]` the easing you want for resets.
`20` is what the example uses.

`construct` is idempotent per frame and internally runs, in order:

1. grow `constructed_bones` from `bones` on the first call, otherwise re-sort it by `id`;
2. `reset_inheritance` → `inheritance`;
3. if `!baked_ik` and IK exists: `reset_inheritance` → `inheritance` → `inverse_kinematics`;
4. if physics exist: `simulate_physics` → `reset_inheritance` → `inheritance(ik_rots, physics)`;
5. `construct_verts` (mesh deformation);
6. `propagate_hidden`.

### Frame helpers

```odin
format_frame :: proc(frame: u32, animation: ^Animation, reverse: bool, is_loop: bool) -> u32
time_frame   :: proc(elapsed_seconds: f32, animation: ^Animation, reverse: bool, is_loop: bool) -> u32
```

`format_frame` applies `% (last_keyframe.frame + 1)` when `is_loop`, then `last - f` when `reverse`.
Returns `0` for an animation with no keyframes. `time_frame` converts seconds using
`animation.fps` and returns `0` when `fps` is not positive.

---

## Lookup helpers

```odin
bone_index_by_id  :: proc(bones: []Bone, id: u32)                 -> (int, bool)
bone_index_by_name:: proc(bones: []Bone, name: string)            -> (int, bool)
find_bone         :: proc(bones: []Bone, id: i32)                 -> (^Bone, bool)
get_visuals       :: proc(visuals: []Visuals, id: i32)            -> (^Visuals, bool)
get_physics       :: proc(physics: []Physics, id: i32)            -> (^Physics, bool)
active_styles     :: proc(armature: ^Armature, allocator := context.allocator) -> []Style
get_bone_texture  :: proc(bone_tex: string, styles: []Style)      -> (Texture, bool)
```

`find_bone`, `get_visuals`, `get_physics` treat a negative id as "not found" and return `false`
out of range; the returned pointer aliases the input slice, so it invalidates on any append.

`active_styles` allocates a new slice (the caller must `delete()` it) and returns the styles a
renderer may be given. It prefers every style flagged `active`; because game exports never carry that
flag it falls back to the style named `"Default"` (case-insensitive), else the last style, else `nil`.

`get_bone_texture` walks the given styles in order and returns the **first** exact-name match.
Pass only `active_styles` (or the one costume the player chose); a returned `Texture.size` of
`(1,1)` means the part is hidden for that costume.

---

## Math helpers

```odin
vec2_add, vec2_sub, vec2_mul, vec2_div :: proc(a, b: Vec2) -> Vec2        // component-wise
vec2_scale, vec2_div_scalar            :: proc(a: Vec2, s: f32) -> Vec2
vec2_magnitude   :: proc(vec: Vec2) -> f32
vec2_normalize   :: proc(vec: Vec2) -> Vec2      // zero vector in, zero vector out
rotate_vec2      :: proc(point: Vec2, rot: f32) -> Vec2   // radians, about the origin
shortest_angle_delta :: proc(from, to: f32) -> f32        // signed, wrapped to (-pi, pi]
is_facing_left   :: proc(scale: Vec2) -> bool
```

`is_facing_left` is the XOR of the two scale signs: `(x<0) != (y<0)`. A scale that is negative on
**both** axes is therefore *not* facing left.

---

## Construction internals

These are public so a custom pipeline can reuse them, but `construct` already calls them in the
right order. Prefer `construct`.

```odin
reset_inheritance  :: proc(constructed_bones: ^[dynamic]Bone, bones: []Bone)
inheritance        :: proc(bones: ^[dynamic]Bone, ik_rots: map[u32]f32, physics: []Physics)
inverse_kinematics :: proc(bones: ^[dynamic]Bone, inverse_kinematics: []InverseKinematics) -> map[u32]f32
point_bones        :: proc(bones: ^[dynamic]Bone, family: ^InverseKinematics)
apply_constraints  :: proc(bones: ^[dynamic]Bone, family: ^InverseKinematics)
fabrik             :: proc(bones: ^[dynamic]Bone, idx: []int, root, target: Vec2)
arc_ik             :: proc(bones: ^[dynamic]Bone, idx: []int, root, target: Vec2)
propagate_hidden   :: proc(bones: ^[dynamic]Bone)
construct_verts    :: proc(bones: ^[dynamic]Bone, visuals: ^[dynamic]Visuals)
inherit_vert       :: proc(pos: Vec2, bone: ^Bone, visuals: ^Visuals) -> Vec2
```

* `inverse_kinematics` returns a **freshly allocated** `map[u32]f32` keyed by bone id; the caller
  must `delete()` it. Families with `target_id == -1` or empty `bone_ids` are skipped.
* `inheritance`'s first parameter is the *constructed* bone slice; `ik_rots` may be `nil`.
* `construct_verts` overwrites `Visuals.vertices[i].pos` in place every frame from `init_pos` plus
  the bone binds, so it is safe to call repeatedly.
* `propagate_hidden` allocates a `[]bool` per call from the ambient allocator and frees it before
  returning.

---

## Ownership summary

| Owner | Freed by |
| --- | --- |
| `SKF.armature` arrays | `armature_destroy` / `skf_destroy` |
| Strings inside the armature | the `json.Value` inside `SKF`, freed by `skf_destroy` |
| `SKF.atlases` PNG buffers | `skf_destroy` |
| `active_styles` result slice | caller, `delete()` |
| `inverse_kinematics` result map | caller, `delete()` |
| Scratch inside `animate`, `propagate_hidden` | the procs themselves |

`armature_destroy` frees **arrays only**, never strings, so it is safe on a hand-built `Armature`
that uses string literals. `skf_destroy` is the one that also drops the JSON tree.

---

## raylib adapter (`example/render.odin`)

`example/` is `package main`, so this is a file to copy into a project, not an importable package.
It owns everything raylib-specific; `main.odin` owns the demo loop. Public surface:

```odin
Construct_Options :: struct {
	position, scale, velocity: skf.Vec2,   // screen pixels, multiplier, fake momentum
}
DEFAULT_CONSTRUCT_OPTIONS :: Construct_Options   // scale {1, 1}, the rest {0, 0}

construct_with_options :: proc(armature: ^skf.Armature, options: Construct_Options = DEFAULT_CONSTRUCT_OPTIONS)
draw_armature          :: proc(armature: ^skf.Armature, textures: []rl.Texture2D, styles: []skf.Style)
draw_bones             :: proc(armature: ^skf.Armature)   // debug overlay, call after draw_armature

load_textures   :: proc(archive: ^skf.SKF)             -> [dynamic]rl.Texture2D
unload_textures :: proc(textures: ^[dynamic]rl.Texture2D)

BONE_COLOR        :: rl.Color{80, 140, 230, 210}
BONE_HIDDEN_COLOR :: rl.Color{220, 90, 90, 120}
```

`construct_with_options` calls `skf.construct` and then rewrites the result in place for screen
space. Per constructed bone: negate `pos.y` and `rot`, multiply `scale` and `pos` by `options.scale`,
add `options.position`, and subtract `options.velocity` from the bone's physics `global_pos`. If
`skf.is_facing_left(options.scale)` it negates `rot` a second time, which puts it back to its
original sign. Every `Visuals.vertices[i].pos` of a bone with a mesh
gets the same negate, scale and translate treatment, so the mesh data is only valid for the frame it
was built in.

`draw_armature` then does, in order:

1. `rlgl.DisableBackfaceCulling()`, left off for the rest of the frame.
2. A stable sort of `constructed_bones` by `Visuals.zindex` **ascending**, through a temporary
   `(zindex, index)` array so the caller's bone order is never mutated. Equal z-index keeps the
   original order, so low z is painted first and high z ends up on top.
3. Per bone, in that order: skip it when `bone.hidden`, when `visuals_id == -1`, when the visual or
   the style lookup misses, or when `Texture.atlas_idx` is outside `textures`. Otherwise the bone is
   drawn as a mesh when `len(visual.vertices) > 0`, and as a sprite quad otherwise.

The vertex colour is `visual.tint` clamped to `0..1` and scaled to `u8`. `Visuals.pivot_rot` applies
to sprite bones only (`bone.rot + pivot_rot * dir`, where `dir` is `1` facing left and `-1` facing
right); `draw_mesh` ignores it.

Three things the adapter does differently from a naive port, all forced by the Y-up to Y-down
mapping. If you write your own renderer, these are the bugs to check for:

1. **Backface culling must stay off.** The mapping reverses triangle winding, so culling drops every
   mesh of an unmirrored armature and keeps only the mirrored one. It matters at batch-flush time, so
   do not `defer` an enable.
2. **Pivot offset order.** `Visuals.pivot_pos` is texture space (Y up), so negate Y *before* rotating
   by the bone: `rotate((pivot_pos * tex.size * bone.scale) with y negated, bone.rot)`. Rotating by
   `bone.rot * dir` and negating afterwards only agrees for one facing direction and makes parts with
   a pivot jump across the body on a flip.
3. **Do not use `rl.DrawTexturePro`** for sprite bones. It derives rotated corners from `dest.width`,
   and a flip makes `bone.scale.x` negative, which is not a clean mirror. Emit the four-corner quad as
   triangles through the same path as meshes.

`rlgl.CheckRenderBatchLimit(n)` is required before emitting vertices, because rlgl's vertex functions
do not grow the render batch themselves and silently drop vertices once it is full. The adapter calls
it once per mesh (with the index count) and once per sprite quad (with 6).

`load_textures` returns one texture per `archive.atlases` entry, in the same order, so the result can
be passed to `draw_armature` as `textures` directly: a missing PNG becomes a zero `rl.Texture2D{}`
placeholder rather than shifting every later index. `unload_textures` frees them and the dynamic
array itself. Both must be called with a live raylib window.

---

## Version

| Component | Version |
| --- | --- |
| SkelForm editor (`.skf` exporter) | 0.8.0 |

`.skf` files carry their own format version as the `version` string in `armature.json`. **No runtime
in this family reads it**, so parsing is version-agnostic. Exports from before 0.6 are not
supported: the editor upgrades those itself on open (`src/backwards_compat.rs`), so re-export old
files from the editor rather than feeding them to a runtime. The armatures in `example/` are 0.7.0
exports and load unchanged.
