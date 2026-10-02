// Package skelform is a pure-Odin port of the generic SkelForm runtime
// (`rusty_skelform` v0.8.0, https://github.com/Retropaint/rusty_skelform, MIT).
//
// Every public type and procedure below mirrors its Rust counterpart one-to-one:
// same names, same field order, same evaluation order and the same (occasionally
// surprising) behaviour, so a diff against `src/lib.rs` stays meaningful.
//
// The one intentional deviation is malformed input. Where the Rust code would
// panic on an out-of-range `unwrap()`/index, this runtime skips the offending
// element; those sites are marked `NOTE(panic-safety):`. Guarded or not, an
// out-of-range index is a clean trap -- unless the build uses
// `-no-bounds-check`, which turns them into silent out-of-bounds access, so
// validate `.skf` files before shipping such a build.
//
// Allocation: `animate`, `construct` and `inverse_kinematics` allocate scratch
// buffers from the ambient `context.allocator` on every call. Point the context at
// a `mem.Scope` to keep that traffic off the heap.
package skelform

import "core:math"
import "core:slice"
import "core:strings"

// ---------------------------------------------------------------------------
// Math types
// ---------------------------------------------------------------------------

Vec2 :: struct {
	x, y: f32,
}

Tint :: struct {
	r, g, b, a: f32,
}

Vertex :: struct {
	pos, uv, init_pos: Vec2,
}

// vec2_add is `Vec2 + Vec2` (component-wise).
vec2_add :: proc(a, b: Vec2) -> Vec2 {return {a.x + b.x, a.y + b.y}}

// vec2_sub is `Vec2 - Vec2` (component-wise).
vec2_sub :: proc(a, b: Vec2) -> Vec2 {return {a.x - b.x, a.y - b.y}}

// vec2_mul is `Vec2 * Vec2` (component-wise).
vec2_mul :: proc(a, b: Vec2) -> Vec2 {return {a.x * b.x, a.y * b.y}}

// vec2_div is `Vec2 / Vec2` (component-wise).
vec2_div :: proc(a, b: Vec2) -> Vec2 {return {a.x / b.x, a.y / b.y}}

// vec2_scale is `Vec2 * f32`.
vec2_scale :: proc(a: Vec2, s: f32) -> Vec2 {return {a.x * s, a.y * s}}

// vec2_div_scalar is `Vec2 / f32`.
vec2_div_scalar :: proc(a: Vec2, s: f32) -> Vec2 {return {a.x / s, a.y / s}}

// vec2_magnitude is the length of the vector.
vec2_magnitude :: proc(vec: Vec2) -> f32 {return magnitude(vec)}

// vec2_normalize returns the unit vector, or the zero vector when the length is 0.
vec2_normalize :: proc(vec: Vec2) -> Vec2 {return normalize(vec)}

// magnitude returns the length of a vector.
@(private = "package")
magnitude :: proc(vec: Vec2) -> f32 {
	return math.sqrt(vec.x * vec.x + vec.y * vec.y)
}

// normalize returns `vec` scaled to unit length (zero vector stays zero).
@(private = "package")
normalize :: proc(vec: Vec2) -> Vec2 {
	mag := magnitude(vec)
	if mag == 0 {
		return Vec2{}
	}
	return {vec.x / mag, vec.y / mag}
}

// rotate_vec2 rotates `point` by `rot` radians around the origin.
rotate_vec2 :: proc(point: Vec2, rot: f32) -> Vec2 {
	return {
		point.x * math.cos(rot) - point.y * math.sin(rot),
		point.x * math.sin(rot) + point.y * math.cos(rot),
	}
}

// shortest_angle_delta returns the signed shortest distance from `from` to `to`,
// wrapped into (-pi, pi].
shortest_angle_delta :: proc(from, to: f32) -> f32 {
	pi: f32 = 3.141592653589793
	tau := pi * 2.0
	delta := to - from
	for delta > pi {
		delta -= tau
	}
	for delta < -pi {
		delta += tau
	}
	return delta
}

// is_facing_left reports whether a bone's scale mirrors it horizontally.
is_facing_left :: proc(scale: Vec2) -> bool {
	both := scale.x < 0 && scale.y < 0
	either := scale.x < 0 || scale.y < 0
	return either && !both
}

// default_tint is the tint used when an armature does not specify one.
@(private = "package")
default_tint :: proc() -> Tint {return {1, 1, 1, 1}}

// ---------------------------------------------------------------------------
// Armature data model
// ---------------------------------------------------------------------------

// AnimElement enumerates the animatable properties. The runtime itself compares
// the `Keyframe.element` string, so this enum is documentation/utility only.
AnimElement :: enum i32 {
	PositionX,
	PositionY,
	Rotation,
	ScaleX,
	ScaleY,
	Zindex,
	Texture,
	IkConstraint,
}

// HandlePreset is the interpolation easing preset of a keyframe.
HandlePreset :: enum i32 {
	Linear,
	SineIn,
	SineOut,
	SineInOut,
	None,
	Custom,
}

// JointConstraint is the side an inverse kinematics family may bend towards.
JointConstraint :: enum i32 {
	None,
	Clockwise,
	CounterClockwise,
}

// InverseKinematicsMode selects the solver used by an IK family.
InverseKinematicsMode :: enum i32 {
	FABRIK,
	Arc,
}

BoneBindVert :: struct {
	id:     u32,
	weight: f32,
}

BoneBind :: struct {
	bone_id: i32,
	is_path: bool,
	verts:   [dynamic]BoneBindVert,
}

Keyframe :: struct {
	frame:         u32,
	bone_id:       u32,
	element:       string,
	value:         f32,
	next_kf:       i32,
	value_str:     string,
	start_handle:  Vec2,
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
	constraint:        string,
	mode:              string,
	target_id:         i32,
	bone_ids:          [dynamic]u32,
	mimic_target:      bool,
	init_constraint:   string,
	init_mode:         string,
	init_mimic_target: bool,
}

Visuals :: struct {
	tex:         string,
	tint:        Tint,
	vertices:    [dynamic]Vertex,
	indices:     [dynamic]u32,
	binds:       [dynamic]BoneBind,
	zindex:      i32,
	pivot_pos:   Vec2,
	pivot_rot:   f32,
	pivot_scale: Vec2,
	init_tex:    string,
	init_zindex: i32,
	init_tint:   Tint,
}

Physics :: struct {
	global_pos:        Vec2,
	pos_damping:       f32,
	pos_ratio:         f32,
	global_rot:        f32,
	global_orbit:      f32,
	global_orbit_diff: f32,
	global_orbit_vel:  f32,
	rot_damping:       f32,
	rot_bounce:        f32,
	rot_vel:           f32,
	sway:              f32,
	global_scale:      Vec2,
	scale_damping:     f32,
	scale_ratio:       f32,
}

Bone :: struct {
	id:           u32,
	name:         string,
	parent_id:    i32,
	rot:          f32,
	scale:        Vec2,
	pos:          Vec2,
	hidden:       bool,
	ik_family_id: i32,
	visuals_id:   i32,
	physics_id:   i32,
	init_rot:     f32,
	init_scale:   Vec2,
	init_pos:     Vec2,
	init_hidden:  bool,
}

Texture :: struct {
	offset:    Vec2,
	size:      Vec2,
	name:      string,
	atlas_idx: u32,
}

Style :: struct {
	id:       u32,
	name:     string,
	active:   bool,
	textures: [dynamic]Texture,
}

TexAtlas :: struct {
	filename: string,
	size:     Vec2,
}

Armature :: struct {
	baked_ik:           bool,
	bones:              [dynamic]Bone,
	constructed_bones:  [dynamic]Bone,
	animations:         [dynamic]Animation,
	textures:           [dynamic]Texture,
	styles:             [dynamic]Style,
	atlases:            [dynamic]TexAtlas,
	inverse_kinematics: [dynamic]InverseKinematics,
	visuals:            [dynamic]Visuals,
	physics:            [dynamic]Physics,
}

// armature_destroy frees every dynamic array owned by the armature.
// Until it is called the armature owns all of its strings and arrays.
armature_destroy :: proc(armature: ^Armature) {
	for i in 0 ..< len(armature.visuals) {
		visual := &armature.visuals[i]
		delete(visual.vertices)
		delete(visual.indices)
		for b in 0 ..< len(visual.binds) {
			delete(visual.binds[b].verts)
		}
		delete(visual.binds)
	}
	for i in 0 ..< len(armature.animations) {
		delete(armature.animations[i].keyframes)
	}
	for i in 0 ..< len(armature.styles) {
		delete(armature.styles[i].textures)
	}
	for i in 0 ..< len(armature.inverse_kinematics) {
		delete(armature.inverse_kinematics[i].bone_ids)
	}
	delete(armature.bones)
	delete(armature.constructed_bones)
	delete(armature.animations)
	delete(armature.textures)
	delete(armature.styles)
	delete(armature.atlases)
	delete(armature.inverse_kinematics)
	delete(armature.visuals)
	delete(armature.physics)
	armature^ = {}
}

// ---------------------------------------------------------------------------
// Lookup helpers (additive convenience; the Rust runtime looks these up inline)
// ---------------------------------------------------------------------------

// bone_index_by_id returns the index of the bone with `id`, or false.
bone_index_by_id :: proc(bones: []Bone, id: u32) -> (int, bool) {
	for i in 0 ..< len(bones) {
		if bones[i].id == id {
			return i, true
		}
	}
	return 0, false
}

// bone_index_by_name returns the index of the first bone named `name`, or false.
bone_index_by_name :: proc(bones: []Bone, name: string) -> (int, bool) {
	for i in 0 ..< len(bones) {
		if bones[i].name == name {
			return i, true
		}
	}
	return 0, false
}

// find_bone returns a pointer into `bones` for the bone with `id` (i32 form, as
// stored on `Bone.parent_id` / `BoneBind.bone_id`). Negative ids never match.
find_bone :: proc(bones: []Bone, id: i32) -> (^Bone, bool) {
	if id < 0 {
		return nil, false
	}
	for i in 0 ..< len(bones) {
		if bones[i].id == u32(id) {
			return &bones[i], true
		}
	}
	return nil, false
}

// bone_at resolves SkelForm's id-as-index convention: a bone's id doubles as its
// index into `bones`, so every id read from the file can be used directly. Off
// range ids -- including negative ones -- return false instead of trapping.
@(private = "package")
bone_at :: proc(bones: []Bone, id: int) -> (^Bone, bool) {
	if id < 0 || id >= len(bones) {
		return nil, false
	}
	return &bones[id], true
}

// get_visuals returns the visual data a bone points at, if any.
get_visuals :: proc(visuals: []Visuals, id: i32) -> (^Visuals, bool) {
	if id < 0 || int(id) >= len(visuals) {
		return nil, false
	}
	return &visuals[int(id)], true
}

// get_physics returns the physics data a bone points at, if any.
get_physics :: proc(physics: []Physics, id: i32) -> (^Physics, bool) {
	if id < 0 || int(id) >= len(physics) {
		return nil, false
	}
	return &physics[int(id)], true
}

// active_styles returns the styles a renderer should draw with.
//
// SkelForm 0.8+ marks the worn costume with `Style.active`; every flagged style is
// returned. Exports that predate the flag (0.7 and older) do not carry it at all, so
// the "Default" style is used instead, falling back to the last style in the file -
// which is what the reference macroquad runtime did for those exports.
//
// Only the returned styles may be searched with `get_bone_texture`: each style holds
// the texture rects of one costume, and a placeholder rect (1x1) means "this costume
// does not include that part".
//
// The slice is freshly allocated; the textures inside still borrow the armature, so
// only `delete(result)` is required.
active_styles :: proc(armature: ^Armature, allocator := context.allocator) -> []Style {
	count := 0
	for i in 0 ..< len(armature.styles) {
		if armature.styles[i].active {
			count += 1
		}
	}
	if count > 0 {
		out := make([]Style, count, allocator)
		j := 0
		for i in 0 ..< len(armature.styles) {
			if armature.styles[i].active {
				out[j] = armature.styles[i]
				j += 1
			}
		}
		return out
	}

	// Legacy export: nothing is flagged. Prefer the style literally named
	// "Default", otherwise the last style.
	index := -1
	for i in 0 ..< len(armature.styles) {
		if strings.equal_fold(armature.styles[i].name, "Default") {
			index = i
			break
		}
	}
	if index < 0 && len(armature.styles) > 0 {
		index = len(armature.styles) - 1
	}
	if index < 0 {
		return nil
	}
	out := make([]Style, 1, allocator)
	out[0] = armature.styles[index]
	return out
}

// get_bone_texture finds the texture named `bone_tex` in the first matching style.
get_bone_texture :: proc(bone_tex: string, styles: []Style) -> (Texture, bool) {
	for s in 0 ..< len(styles) {
		for t in 0 ..< len(styles[s].textures) {
			if styles[s].textures[t].name == bone_tex {
				return styles[s].textures[t], true
			}
		}
	}
	return {}, false
}

// ---------------------------------------------------------------------------
// Interpolation
// ---------------------------------------------------------------------------

// f32_as_u32 mirrors Rust's saturating `f32 as u32` cast (NaN/negative -> 0,
// out of range -> u32 max), which Odin's raw cast does not guarantee.
@(private = "package")
f32_as_u32 :: proc(f: f32) -> u32 {
	if !(f > 0) {
		return 0
	}
	if f >= 4294967295.0 {
		return max(u32)
	}
	return u32(f)
}

@(private = "package")
cubic_bezier :: proc(t, p1, p2: f32) -> f32 {
	u := 1.0 - t
	return 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t
}

@(private = "package")
cubic_bezier_derivative :: proc(t, p1, p2: f32) -> f32 {
	u := 1.0 - t
	return 3.0 * u * u * p1 + 6.0 * u * t * (p2 - p1) + 3.0 * t * t * (1.0 - p2)
}

// interpolate eases from `start_val` to `end_val`, solving the cubic bezier for
// time with Newton-Raphson. A handle `y` of 999 on both sides means "snap".
@(private = "package")
interpolate :: proc(current, max: u32, start_val, end_val: f32, start_handle, end_handle: Vec2) -> f32 {
	// snapping behavior for None transition preset
	if start_handle.y == 999.0 && end_handle.y == 999.0 {
		return start_val
	}
	if max == 0 || current >= max {
		return end_val
	}

	initial := f32(current) / f32(max)
	t := initial
	for _ in 0 ..< 5 {
		x := cubic_bezier(t, start_handle.x, end_handle.x)
		dx := cubic_bezier_derivative(t, start_handle.x, end_handle.x)
		if math.abs(dx) < 1e-5 {
			break
		}
		t -= (x - initial) / dx
		t = math.clamp(t, 0.0, 1.0)
	}

	progress := cubic_bezier(t, start_handle.y, end_handle.y)
	return start_val + (end_val - start_val) * progress
}

@(private = "file")
interpolate_keyframes :: proc(field: ^f32, prev_kf, next_kf: ^Keyframe, frame, smooth_frames: u32) {
	total_frames := next_kf.frame - prev_kf.frame
	current_frame := frame - prev_kf.frame

	result := interpolate(
		current_frame,
		total_frames,
		prev_kf.value,
		next_kf.value,
		next_kf.start_handle,
		next_kf.end_handle,
	)

	z := Vec2{}
	field^ = interpolate(current_frame, smooth_frames, field^, result, z, z)
}

// ---------------------------------------------------------------------------
// Animation
// ---------------------------------------------------------------------------

// Animated_Element names the bone/visual/IK elements an animation can drive.
// `animate` keeps one bit set per bone to remember which elements a keyframe
// touched, so only untouched elements are reset to their initial value.
@(private = "file")
Animated_Element :: enum u8 {
	PositionX,
	PositionY,
	Rotation,
	ScaleX,
	ScaleY,
	Hidden,
	TintR,
	TintG,
	TintB,
	TintA,
	Texture,
	IkConstraint,
	MimicTarget,
	Zindex,
}

@(private = "file")
Animated_Elements :: bit_set[Animated_Element]

// animated_element maps a keyframe's `element` string onto its flag. Unknown
// elements report `known = false`; they never drive a runtime field, so they can
// be ignored when tracking resets.
@(private = "file")
animated_element :: proc(element: string) -> (flag: Animated_Element, known: bool) {
	switch element {
	case "PositionX":
		return .PositionX, true
	case "PositionY":
		return .PositionY, true
	case "Rotation":
		return .Rotation, true
	case "ScaleX":
		return .ScaleX, true
	case "ScaleY":
		return .ScaleY, true
	case "Hidden":
		return .Hidden, true
	case "TintR":
		return .TintR, true
	case "TintG":
		return .TintG, true
	case "TintB":
		return .TintB, true
	case "TintA":
		return .TintA, true
	case "Tex":
		return .Texture, true
	case "IkConstraint":
		return .IkConstraint, true
	case "MimicTarget":
		return .MimicTarget, true
	case "Zindex":
		return .Zindex, true
	}
	return .PositionX, false
}

// animate processes bones with animations.
//
// `anims` is indexed in parallel with `frames` and `smooth_frames` (one entry
// per playing animation).
animate :: proc(
	bones: ^[dynamic]Bone,
	inverse_kinematics: ^[dynamic]InverseKinematics,
	visuals: ^[dynamic]Visuals,
	anims: []Animation,
	frames: []u32,
	smooth_frames: []u32,
) {
	// `frames` / `smooth_frames` are indexed both per animation and, below, at [0].
	if len(frames) == 0 || len(smooth_frames) == 0 {
		return // NOTE(panic-safety): Rust panics on an empty `frames`
	}

	// keeps track of animated elements. Bone elements not included will be reset
	reset_map := make(map[u32]Animated_Elements)
	defer delete(reset_map)

	for a in 0 ..< min(len(anims), len(frames), len(smooth_frames)) {
		for k in 0 ..< len(anims[a].keyframes) {
			kf := &anims[a].keyframes[k]

			// skip animation if current keyframes are beyond this frame
			if kf.frame > frames[a] {
				break
			}

			// set next_kf to itself, if it's -1
			nkf := kf.next_kf
			if nkf == -1 {
				nkf = i32(k)
			}
			if nkf < 0 || int(nkf) >= len(anims[a].keyframes) {
				continue // NOTE(panic-safety): `next_kf` is an unchecked file field
			}

			next_kf := &anims[a].keyframes[nkf]

			// skip keyframe if it's not the last, and would not be animated
			is_last := nkf == i32(k)
			is_before_frame := next_kf.frame < frames[a]
			if is_before_frame && !is_last {
				continue
			}

			bone, ok := bone_at(bones[:], int(kf.bone_id))
			if !ok {
				continue // NOTE(panic-safety): Rust indexes out of bounds here
			}

			// Add this keyframe's bone and element to the map, which is used to decide
			// whether a bone element has to be reset later. Calibrated against
			// skelform_go: only keyframes that are actually applied count as animated.
			if element, known := animated_element(kf.element); known {
				elements := reset_map[kf.bone_id]
				elements += {element}
				reset_map[kf.bone_id] = elements
			}

			f := frames[a]
			bf := smooth_frames[a]

			// animate basic fields
			switch kf.element {
			case "PositionX":
				interpolate_keyframes(&bone.pos.x, kf, next_kf, f, bf)
			case "PositionY":
				interpolate_keyframes(&bone.pos.y, kf, next_kf, f, bf)
			case "Rotation":
				interpolate_keyframes(&bone.rot, kf, next_kf, f, bf)
			case "ScaleX":
				interpolate_keyframes(&bone.scale.x, kf, next_kf, f, bf)
			case "ScaleY":
				interpolate_keyframes(&bone.scale.y, kf, next_kf, f, bf)
			case "Hidden":
				bone.hidden = kf.value == 1.0
			}

			// animate visual fields
			if visual, ok := get_visuals(visuals^[:], bone.visuals_id); ok {
				switch kf.element {
				case "TintR":
					interpolate_keyframes(&visual.tint.r, kf, next_kf, f, bf)
				case "TintG":
					interpolate_keyframes(&visual.tint.g, kf, next_kf, f, bf)
				case "TintB":
					interpolate_keyframes(&visual.tint.b, kf, next_kf, f, bf)
				case "TintA":
					interpolate_keyframes(&visual.tint.a, kf, next_kf, f, bf)
				case "Tex":
					visual.tex = kf.value_str
				}
			}

			// animate inverse kinematics fields
			if ik, ok := get_ik_family(inverse_kinematics^[:], bone.ik_family_id); ok {
				switch kf.element {
				case "IkConstraint":
					ik.constraint = kf.value_str
				case "MimicTarget":
					ik.mimic_target = kf.value == 1.0
				}
			}
		}
	}

	// reset non-animated bone elements
	sf := smooth_frames[0]
	f := frames[0]
	for b in 0 ..< len(bones) {
		bone := &bones[b]

		elements := reset_map[bone.id]

		z := Vec2{}

		// reset basic fields
		if .PositionX not_in elements {
			bone.pos.x = interpolate(f, sf, bone.pos.x, bone.init_pos.x, z, z)
		}
		if .PositionY not_in elements {
			bone.pos.y = interpolate(f, sf, bone.pos.y, bone.init_pos.y, z, z)
		}
		if .Rotation not_in elements {
			bone.rot = interpolate(f, sf, bone.rot, bone.init_rot, z, z)
		}
		if .ScaleX not_in elements {
			bone.scale.x = interpolate(f, sf, bone.scale.x, bone.init_scale.x, z, z)
		}
		if .ScaleY not_in elements {
			bone.scale.y = interpolate(f, sf, bone.scale.y, bone.init_scale.y, z, z)
		}
		if .Hidden not_in elements {
			bone.hidden = bone.init_hidden
		}

		// reset visuals data
		if visual, ok := get_visuals(visuals^[:], bone.visuals_id); ok {
			if .Texture not_in elements {
				visual.tex = visual.init_tex
			}
			if .TintR not_in elements {
				visual.tint.r = interpolate(f, sf, visual.tint.r, visual.init_tint.r, z, z)
			}
			if .TintG not_in elements {
				visual.tint.g = interpolate(f, sf, visual.tint.g, visual.init_tint.g, z, z)
			}
			if .TintB not_in elements {
				visual.tint.b = interpolate(f, sf, visual.tint.b, visual.init_tint.b, z, z)
			}
			if .TintA not_in elements {
				visual.tint.a = interpolate(f, sf, visual.tint.a, visual.init_tint.a, z, z)
			}
		}

		// reset inverse kinematics data
		if ik, ok := get_ik_family(inverse_kinematics^[:], bone.ik_family_id); ok {
			if .IkConstraint not_in elements {
				ik.constraint = ik.init_constraint
			}
			if .MimicTarget not_in elements {
				ik.mimic_target = ik.init_mimic_target
			}
		}
	}
}

// get_ik_family indexes an inverse kinematics family by `Bone.ik_family_id`
// (mirrors `inverse_kinematics.get_mut(bone.ik_family_id as usize)`).
@(private = "file")
get_ik_family :: proc(families: []InverseKinematics, id: i32) -> (^InverseKinematics, bool) {
	if id < 0 || int(id) >= len(families) {
		return nil, false
	}
	return &families[int(id)], true
}

// ---------------------------------------------------------------------------
// Animation frame helpers
// ---------------------------------------------------------------------------

// format_frame wraps/reverses a raw frame counter for an animation.
format_frame :: proc(frame: u32, animation: ^Animation, reverse: bool, is_loop: bool) -> u32 {
	if len(animation.keyframes) == 0 {
		return 0 // NOTE(panic-safety): Rust unwraps the last keyframe here
	}
	last_frame := animation.keyframes[len(animation.keyframes) - 1].frame

	f := frame
	if is_loop {
		f %= last_frame + 1
	}
	if reverse {
		f = last_frame - f
	}
	return f
}

// time_frame converts elapsed seconds into an animation frame.
// (`rusty_skelform::time_frame` takes a `std::time::Instant`; callers pass
// `f32(time.duration_seconds(time.since(start)))` or similar.)
time_frame :: proc(elapsed_seconds: f32, animation: ^Animation, reverse: bool, is_loop: bool) -> u32 {
	frametime := 1.0 / f32(animation.fps)
	if !(frametime > 0) {
		return 0
	}
	frame := f32_as_u32(elapsed_seconds / frametime)
	return format_frame(frame, animation, reverse, is_loop)
}

// ---------------------------------------------------------------------------
// Construction pipeline
// ---------------------------------------------------------------------------

// inheritance applies child-parent inheritance.
// Must be run twice, before and after `inverse_kinematics()`.
inheritance :: proc(bones: ^[dynamic]Bone, ik_rots: map[u32]f32, physics: []Physics) {
	for b in 0 ..< len(bones) {
		if parent, has_parent := bone_at(bones[:], int(bones[b].parent_id)); has_parent {
			parent_pos := parent.pos
			parent_scale := parent.scale

			orbit_rot := parent.rot
			// apply orbital difference, if rotation resistance physics is active
			if phys, ok := get_physics(physics, bones[b].physics_id); ok {
				if phys.sway > 0 {
					orbit_rot -= phys.global_orbit_diff
				}
			}

			if is_facing_left(parent.scale) {
				bones[b].rot = -bones[b].rot
			}

			bones[b].rot += orbit_rot

			bones[b].scale = vec2_mul(bones[b].scale, parent_scale)
			bones[b].pos = vec2_mul(bones[b].pos, parent_scale)

			// orbit the parent
			bones[b].pos = rotate_vec2(bones[b].pos, orbit_rot)

			bones[b].pos = vec2_add(bones[b].pos, parent_pos)
		}

		if ik_rot, ok := ik_rots[u32(b)]; ok {
			bones[b].rot = ik_rot
		}

		// apply physics, if physics data is provided
		if phys, ok := get_physics(physics, bones[b].physics_id); ok {
			if phys.rot_damping > 0 {
				bones[b].rot = phys.global_rot
			}
			if phys.pos_damping > 0 {
				bones[b].pos = phys.global_pos
			}
			if phys.scale_damping > 0 {
				bones[b].scale = phys.global_scale
			}
		}
	}
}

// reset_inheritance always runs this before `inheritance()`.
reset_inheritance :: proc(constructed_bones: ^[dynamic]Bone, bones: []Bone) {
	for b in 0 ..< len(bones) {
		constructed_bones[b].pos = bones[b].pos
		constructed_bones[b].rot = bones[b].rot
		constructed_bones[b].scale = bones[b].scale
	}
}

// construct builds `armature.constructed_bones` (transforms + deformed meshes).
construct :: proc(armature: ^Armature) {
	const_bones := &armature.constructed_bones

	// initialize constructed_bones
	if len(const_bones) == 0 {
		for i in 0 ..< len(armature.bones) {
			append(const_bones, armature.bones[i])
		}
	} else {
		slice.sort_by(const_bones^[:], proc(a, b: Bone) -> bool {return a.id < b.id})
	}

	// 1st inheritance pass
	reset_inheritance(const_bones, armature.bones[:])
	inheritance(const_bones, nil, nil)

	// 2nd inheritance pass: inverse kinematics
	ik_rots: map[u32]f32
	if !armature.baked_ik && len(armature.inverse_kinematics) > 0 {
		reset_inheritance(const_bones, armature.bones[:])
		inheritance(const_bones, nil, nil)
		ik_rots = inverse_kinematics(const_bones, armature.inverse_kinematics[:])
	}
	defer delete(ik_rots)

	// 3rd inheritance pass: physics
	if len(armature.physics) > 0 {
		simulate_physics(const_bones, &armature.physics)
		reset_inheritance(const_bones, armature.bones[:])
		inheritance(const_bones, ik_rots, armature.physics[:])
	}

	// mesh deformation
	construct_verts(const_bones, &armature.visuals)

	propagate_hidden(const_bones)
}

// propagate_hidden makes children of hidden bones hidden as well.
propagate_hidden :: proc(bones: ^[dynamic]Bone) {
	hiddens := make([]bool, len(bones))
	defer delete(hiddens)

	for b in 0 ..< len(bones) {
		bone := &bones[b]
		// save this bone's hidden status so it can be propagated to its children,
		// and ignore rendering if it's hidden
		is_parent_hidden := bone.parent_id >= 0 &&
			int(bone.parent_id) < len(hiddens) &&
			hiddens[bone.parent_id]
		if bone.hidden || is_parent_hidden {
			bone.hidden = true
			if int(bone.id) < len(hiddens) {
				hiddens[int(bone.id)] = true
			}
		}
	}
}

@(private = "file")
simulate_physics :: proc(constructed_bones: ^[dynamic]Bone, physics: ^[dynamic]Physics) {
	for b in 0 ..< len(constructed_bones) {
		if constructed_bones[b].physics_id == -1 {
			continue
		}
		if int(constructed_bones[b].physics_id) >= len(physics) {
			continue // NOTE(panic-safety): Rust indexes out of bounds here
		}
		phys := &physics[int(constructed_bones[b].physics_id)]
		const_bone := &constructed_bones[b]

		s := Vec2{0.3, 0.3}
		e := Vec2{0.6, 0.6}
		prev_pos := phys.global_pos

		// interpolate position
		if phys.pos_damping > 0 || phys.sway > 0 {
			phys_pos := &phys.global_pos
			damping := Vec2{phys.pos_damping, phys.pos_damping}

			// ratio
			if phys.pos_ratio < 0 {
				damping.y *= 1.0 - math.abs(phys.pos_ratio)
			} else if phys.pos_ratio > 0 {
				damping.x *= 1.0 - phys.pos_ratio
			}

			phys_pos.x = interpolate(2, f32_as_u32(damping.x), phys_pos.x, const_bone.pos.x, s, e)
			phys_pos.y = interpolate(2, f32_as_u32(damping.y), phys_pos.y, const_bone.pos.y, s, e)
		}

		// interpolate scale
		if phys.scale_damping > 0 {
			phys_scale := &phys.global_scale
			damping := Vec2{phys.scale_damping, phys.scale_damping}

			// ratio
			if phys.scale_ratio < 0 {
				damping.y *= 1.0 - math.abs(phys.scale_ratio)
			} else if phys.scale_ratio > 0 {
				// NOTE: calibrated against skelform_go, which tests `scale_ratio` here.
				// rusty_skelform v0.8.0 mistakenly tests `pos_ratio` instead.
				damping.x *= 1.0 - phys.scale_ratio
			}

			phys_scale.x = interpolate(2, f32_as_u32(damping.x), phys_scale.x, const_bone.scale.x, s, e)
			phys_scale.y = interpolate(2, f32_as_u32(damping.y), phys_scale.y, const_bone.scale.y, s, e)
		}

		// interpolate rotation
		if phys.rot_damping > 0 {
			rot := shortest_angle_delta(phys.global_rot, const_bone.rot)
			phys.global_rot += rot / phys.rot_damping
		}

		// interpolate parent orbit (rot res, bounce, etc)
		parent, parent_ok := find_bone(constructed_bones^[:], const_bone.parent_id)
		if phys.sway > 0 && parent_ok {
			// interpolate to the angle difference between bone and parent
			diff := normalize(vec2_sub(const_bone.pos, parent.pos))
			diff_angle := math.atan2(diff.y, diff.x)
			orbit_buffer := shortest_angle_delta(phys.global_orbit, diff_angle)

			// apply bounce
			if phys.rot_bounce > 0 && phys.rot_bounce <= 1 {
				orbit_buffer += phys.global_orbit_vel / (2.0 - phys.rot_bounce)
				phys.global_orbit_vel = orbit_buffer
			}
			phys.global_orbit += orbit_buffer / 10.0

			// swing orbit based on position momentum
			vel := normalize(vec2_sub(phys.global_pos, prev_pos))
			angle := math.atan2(-vel.y, -vel.x)
			vel_rot := shortest_angle_delta(phys.global_orbit, angle)
			strength := magnitude(vec2_sub(phys.global_pos, prev_pos)) / 1000.0
			phys.global_orbit += vel_rot * strength * phys.sway

			phys.global_orbit_diff = diff_angle - phys.global_orbit
		}
	}
}

// construct_verts deforms the meshes of `visuals` for the given (constructed) bones.
construct_verts :: proc(bones: ^[dynamic]Bone, visuals: ^[dynamic]Visuals) {
	for b in 0 ..< len(bones) {
		if bones[b].visuals_id == -1 {
			continue
		}
		visual, ok := get_visuals(visuals^[:], bones[b].visuals_id)
		if !ok {
			continue // NOTE(panic-safety): Rust indexes out of bounds here
		}

		// move vertex to main bone.
		// this will be overridden if vertex has a bind.
		for v in 0 ..< len(visual.vertices) {
			visual.vertices[v].pos = visual.vertices[v].init_pos
			visual.vertices[v].pos = inherit_vert(visual.vertices[v].pos, &bones[b], visual)
		}

		for bi in 0 ..< len(visual.binds) {
			b_id := visual.binds[bi].bone_id
			if b_id == -1 {
				continue
			}
			found_bind_bone, bind_ok := find_bone(bones^[:], b_id)
			if !bind_ok {
				continue // NOTE(panic-safety): Rust unwraps here
			}
			bind_bone := found_bind_bone^

			for v in 0 ..< len(visual.binds[bi].verts) {
				vert_id := visual.binds[bi].verts[v].id
				if int(vert_id) >= len(visual.vertices) {
					continue // NOTE(panic-safety): `vert_id` is an unchecked file field
				}

				if !visual.binds[bi].is_path {
					// weights
					weight := visual.binds[bi].verts[v].weight
					init_pos := visual.vertices[vert_id].init_pos
					end_pos := vec2_sub(
						inherit_vert(init_pos, &bind_bone, visual),
						visual.vertices[vert_id].pos,
					)
					visual.vertices[vert_id].pos = vec2_add(
						visual.vertices[vert_id].pos,
						vec2_scale(end_pos, weight),
					)
					continue
				}

				// pathing:
				// Bone binds are treated as one continuous line.
				// Vertices will follow along this path.

				// get previous and next bone
				prev := bi
				if bi > 0 {
					prev = bi - 1
				}
				next := min(bi + 1, len(visual.binds) - 1)

				prev_bone, prev_ok := find_bone(bones^[:], visual.binds[prev].bone_id)
				next_bone, next_ok := find_bone(bones^[:], visual.binds[next].bone_id)
				if !prev_ok || !next_ok {
					continue // NOTE(panic-safety): Rust unwraps here
				}

				// get the average of normals between previous bone, this bone, and next bone
				prev_dir := vec2_sub(bind_bone.pos, prev_bone.pos)
				next_dir := vec2_sub(next_bone.pos, bind_bone.pos)
				prev_normal := normalize(Vec2{-prev_dir.y, prev_dir.x})
				next_normal := normalize(Vec2{-next_dir.y, next_dir.x})
				average := vec2_add(prev_normal, next_normal)
				normal_angle := math.atan2(average.y, average.x)

				// move vertex to bind bone, then just adjust it to 'bounce' off the line's surface
				visual.vertices[vert_id].pos = vec2_add(visual.vertices[vert_id].init_pos, bind_bone.pos)
				rotated := rotate_vec2(vec2_sub(visual.vertices[vert_id].pos, bind_bone.pos), normal_angle)
				visual.vertices[vert_id].pos = vec2_add(
					bind_bone.pos,
					vec2_scale(rotated, visual.binds[bi].verts[v].weight),
				)
			}
		}
	}
}

// inherit_vert transforms a vertex from bone space into armature space.
inherit_vert :: proc(pos: Vec2, bone: ^Bone, visuals: ^Visuals) -> Vec2 {
	p := pos
	p = vec2_mul(p, vec2_mul(bone.scale, visuals.pivot_scale))
	p = rotate_vec2(p, bone.rot + visuals.pivot_rot)
	p = vec2_add(p, bone.pos)
	return p
}

// ---------------------------------------------------------------------------
// Inverse kinematics
// ---------------------------------------------------------------------------

// inverse_kinematics returns the rotations of the affected bones, keyed by bone id.
// The caller owns the returned map and must `delete()` it.
// Must be run between two `inheritance()`, with the 2nd call using rotations from this.
inverse_kinematics :: proc(bones: ^[dynamic]Bone, inverse_kinematics: []InverseKinematics) -> map[u32]f32 {
	ik_rot := make(map[u32]f32)

	for fi in 0 ..< len(inverse_kinematics) {
		family := &inverse_kinematics[fi]
		if family.target_id == -1 {
			continue
		}
		if len(family.bone_ids) == 0 {
			continue // NOTE(panic-safety): Rust indexes bone_ids[0] here
		}
		target_bone, target_ok := bone_at(bones[:], int(family.target_id))
		root, root_ok := bone_at(bones[:], int(family.bone_ids[0]))
		if !target_ok || !root_ok {
			continue // NOTE(panic-safety): Rust indexes out of bounds here
		}

		root_pos := root.pos
		target := target_bone.pos

		// Rust collects `&mut Bone` in bone order, filtered by membership.
		family_idxs := make([dynamic]int, 0, len(family.bone_ids))
		defer delete(family_idxs)
		for i in 0 ..< len(bones) {
			if slice.contains(family.bone_ids[:], bones[i].id) {
				append(&family_idxs, i)
			}
		}

		if family.mode == "FABRIK" {
			for _ in 0 ..< 10 {
				fabrik(bones, family_idxs[:], root_pos, target)
			}
		} else {
			arc_ik(bones, family_idxs[:], root_pos, target)
		}
		point_bones(bones, family)
		apply_constraints(bones, family)
		for b in 0 ..< len(family.bone_ids) {
			if b == len(family.bone_ids) - 1 {
				if family.mimic_target {
					ik_rot[family.bone_ids[b]] = target_bone.rot
				}
				continue
			}
			if bone, ok := bone_at(bones[:], int(family.bone_ids[b])); ok {
				ik_rot[family.bone_ids[b]] = bone.rot
			}
		}
	}

	return ik_rot
}

// point_bones aims every bone of the family at the tip bone.
// NOTE: like the Rust runtime, `bone_ids` are used as direct indices into `bones`.
point_bones :: proc(bones: ^[dynamic]Bone, family: ^InverseKinematics) {
	if len(family.bone_ids) == 0 {
		return
	}
	last := family.bone_ids[len(family.bone_ids) - 1]
	if int(last) >= len(bones) {
		return // NOTE(panic-safety): Rust indexes out of bounds here
	}
	tip_pos := bones[last].pos

	for i := len(family.bone_ids) - 1; i >= 0; i -= 1 {
		b := family.bone_ids[i]
		if int(b) >= len(bones) {
			continue
		}
		bone := &bones[b]
		if i == len(family.bone_ids) - 1 {
			continue
		}

		dir := vec2_sub(tip_pos, bone.pos)
		bone.rot = math.atan2(dir.y, dir.x)
		tip_pos = bone.pos
	}
}

// apply_constraints mirrors a whole IK family when it bends the wrong way.
apply_constraints :: proc(bones: ^[dynamic]Bone, family: ^InverseKinematics) {
	target_bone, target_ok := bone_at(bones[:], int(family.target_id))
	if !target_ok {
		return // NOTE(panic-safety): Rust indexes these directly
	}
	if len(family.bone_ids) < 2 {
		return // NOTE(panic-safety): Rust indexes bone_ids[1] here
	}
	root_bone, root_ok := bone_at(bones[:], int(family.bone_ids[0]))
	joint_bone, joint_ok := bone_at(bones[:], int(family.bone_ids[1]))
	if !root_ok || !joint_ok {
		return
	}

	root := root_bone.pos
	target := target_bone.pos
	joint_dir := normalize(vec2_sub(joint_bone.pos, root))
	base_dir := normalize(vec2_sub(target, root))
	dir := joint_dir.x * base_dir.y - base_dir.x * joint_dir.y
	base_angle := math.atan2(base_dir.y, base_dir.x)

	cw := family.constraint == "Clockwise" && dir > 0
	ccw := family.constraint == "CounterClockwise" && dir < 0
	if ccw || cw {
		for i in 0 ..< len(family.bone_ids) {
			b := family.bone_ids[i]
			if int(b) >= len(bones) {
				continue
			}
			bones[b].rot = -bones[b].rot + base_angle * 2.0
		}
	}
}

// fabrik solves the family with the FABRIK algorithm (forward + backward pass).
// `idx` lists the family's bone indices into `bones`, in bone order.
// https://www.youtube.com/watch?v=NfuO66wsuRg
fabrik :: proc(bones: ^[dynamic]Bone, idx: []int, root, target: Vec2) {
	if len(idx) == 0 {
		return
	}

	// forward-reaching
	next_pos := target
	next_length: f32 = 0
	for b := len(idx) - 1; b >= 0; b -= 1 {
		length := vec2_scale(vec2_normalize(vec2_sub(next_pos, bones[idx[b]].pos)), next_length)
		if b != 0 {
			next_length = magnitude(vec2_sub(bones[idx[b]].pos, bones[idx[b - 1]].pos))
		}
		bones[idx[b]].pos = vec2_sub(next_pos, length)
		next_pos = bones[idx[b]].pos
	}

	// backward-reaching
	prev_pos := root
	prev_length: f32 = 0
	for b in 0 ..< len(idx) {
		length := vec2_scale(vec2_normalize(vec2_sub(prev_pos, bones[idx[b]].pos)), prev_length)
		if b != len(idx) - 1 {
			prev_length = magnitude(vec2_sub(bones[idx[b]].pos, bones[idx[b + 1]].pos))
		}
		bones[idx[b]].pos = vec2_sub(prev_pos, length)
		prev_pos = bones[idx[b]].pos
	}
}

// arc_ik bends the family along an arc towards the target.
arc_ik :: proc(bones: ^[dynamic]Bone, idx: []int, root, target: Vec2) {
	if len(idx) == 0 {
		return
	}

	// determine where bones will be on the arc line (ranging from 0 to 1)
	dist := make([dynamic]f32, 0, len(idx))
	defer delete(dist)
	append(&dist, 0)

	max_length := magnitude(vec2_sub(bones[idx[len(idx) - 1]].pos, root))
	curr_length: f32 = 0
	for b in 1 ..< len(idx) {
		length := magnitude(vec2_sub(bones[idx[b]].pos, bones[idx[b - 1]].pos))
		curr_length += length
		append(&dist, curr_length / max_length)
	}

	base := vec2_sub(target, root)
	base_angle := math.atan2(base.y, base.x)
	base_mag := min(magnitude(base), max_length)
	peak := max_length / base_mag
	valley := base_mag / max_length

	for b in 1 ..< len(idx) {
		bones[idx[b]].pos = Vec2 {
			bones[idx[b]].pos.x * valley,
			root.y + (1.0 - peak) * math.sin(dist[b] * 3.14) * base_mag,
		}

		rotated := rotate_vec2(vec2_sub(bones[idx[b]].pos, root), base_angle)
		bones[idx[b]].pos = vec2_add(rotated, root)
	}
}
