// .skf loading for the Odin SkelForm runtime.
//
// A `.skf` file is a plain ZIP archive produced by the SkelForm editor:
//
//   armature.json   the runtime data (see `armature_parse_json`)
//   atlas0.png ...  one PNG per entry of `Armature.atlases`
//   editor.json, thumbnail.png, readme.md   editor-only extras (ignored)
//
// This file implements a small ZIP reader (stored + deflate entries) on top of
// `core:compress/zlib` and maps `armature.json` onto `Armature` with the same
// defaults serde applies in `rusty_skelform`.
//
// Ownership: `Armature` borrows its strings. Everything an `SKF` returns is
// owned by the `SKF` until `skf_destroy` is called.
package skelform

import "core:bytes"
import "core:compress/zlib"
import "core:encoding/json"
import "core:os"

// ---------------------------------------------------------------------------
// ZIP reader
// ---------------------------------------------------------------------------

@(private = "file")
Zip_Entry :: struct {
	name: string,
	data: []u8,
}

@(private = "file")
Zip :: struct {
	entries:  [dynamic]Zip_Entry,
	inflated: [dynamic][]u8,
}

@(private = "file")
ZIP_LOCAL_SIGNATURE :: u32(0x04034b50)

@(private = "file")
ZIP_CENTRAL_SIGNATURE :: u32(0x02014b50)

@(private = "file")
ZIP_EOCD_SIGNATURE :: u32(0x06054b50)

@(private = "file")
le_u16 :: proc(b: []u8, at: int) -> (u16, bool) {
	if at < 0 || at + 2 > len(b) {
		return 0, false
	}
	return u16(b[at]) | u16(b[at + 1]) << 8, true
}

@(private = "file")
le_u32 :: proc(b: []u8, at: int) -> (u32, bool) {
	if at < 0 || at + 4 > len(b) {
		return 0, false
	}
	return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24, true
}

@(private = "file")
zip_close :: proc(zip: ^Zip) {
	for i in 0 ..< len(zip.inflated) {
		delete(zip.inflated[i])
	}
	delete(zip.inflated)
	delete(zip.entries)
	zip^ = {}
}

// zip_open reads the central directory of `data` and resolves every entry to its
// bytes. Stored entries borrow `data`; deflated entries are inflated into freshly
// allocated buffers tracked by the returned `Zip`.
@(private = "file")
zip_open :: proc(data: []u8) -> (zip: Zip, ok: bool) {
	if len(data) < 22 {
		return {}, false
	}

	// Locate the end-of-central-directory record (scan back over the comment).
	eocd := -1
	scan_start := len(data) - 22
	scan_end := max(0, len(data) - 22 - 65535)
	for i := scan_start; i >= scan_end; i -= 1 {
		if sig, sig_ok := le_u32(data, i); sig_ok && sig == ZIP_EOCD_SIGNATURE {
			eocd = i
			break
		}
	}
	if eocd < 0 {
		return {}, false
	}

	count, c_ok := le_u16(data, eocd + 10)
	cd_offset, o_ok := le_u32(data, eocd + 16)
	if !c_ok || !o_ok {
		return {}, false
	}

	zip.entries = make([dynamic]Zip_Entry, 0, count)
	zip.inflated = make([dynamic][]u8, 0)

	pos := int(cd_offset)
	for _ in 0 ..< int(count) {
		if pos + 46 > len(data) {
			break
		}
		sig, sig_ok := le_u32(data, pos)
		if !sig_ok || sig != ZIP_CENTRAL_SIGNATURE {
			break
		}

		method, _ := le_u16(data, pos + 10)
		comp_size, _ := le_u32(data, pos + 20)
		uncomp_size, _ := le_u32(data, pos + 24)
		name_len, _ := le_u16(data, pos + 28)
		extra_len, _ := le_u16(data, pos + 30)
		comment_len, _ := le_u16(data, pos + 32)
		local_offset, _ := le_u32(data, pos + 42)

		name_start := pos + 46
		if name_start + int(name_len) > len(data) {
			break
		}
		name := string(data[name_start:name_start + int(name_len)])

		// Resolve the payload through the local header (the central directory
		// sizes are authoritative, the local header adds its own name/extra).
		lh := int(local_offset)
		if lh + 30 > len(data) {
			pos += 46 + int(name_len) + int(extra_len) + int(comment_len)
			continue
		}
		local_sig, _ := le_u32(data, lh)
		local_name_len, _ := le_u16(data, lh + 26)
		local_extra_len, _ := le_u16(data, lh + 28)
		data_start := lh + 30 + int(local_name_len) + int(local_extra_len)
		data_end := data_start + int(comp_size)

		if local_sig == ZIP_LOCAL_SIGNATURE && data_start >= 0 && data_end <= len(data) {
			comp := data[data_start:data_end]
			switch method {
			case 0:
				// stored
				append(&zip.entries, Zip_Entry{name = name, data = comp})
			case 8:
				// deflate
				buf: bytes.Buffer
				bytes.buffer_init_allocator(&buf, 0, int(uncomp_size))
				if err := zlib.inflate_from_byte_array(comp, &buf, true, int(uncomp_size)); err == nil {
					out := bytes.buffer_to_bytes(&buf)
					append(&zip.inflated, out)
					append(&zip.entries, Zip_Entry{name = name, data = out})
				} else {
					bytes.buffer_destroy(&buf)
				}
			case:
			// Unsupported compression method: skip the entry.
			}
		}

		pos += 46 + int(name_len) + int(extra_len) + int(comment_len)
	}

	return zip, true
}

@(private = "file")
zip_find :: proc(zip: ^Zip, name: string) -> ([]u8, bool) {
	for i in 0 ..< len(zip.entries) {
		if zip.entries[i].name == name {
			return zip.entries[i].data, true
		}
	}
	return nil, false
}

// ---------------------------------------------------------------------------
// JSON -> Armature
// ---------------------------------------------------------------------------

@(private = "file")
j_object :: proc(o: json.Object, key: string) -> (json.Object, bool) {
	if v, ok := o[key]; ok {
		if obj, is_obj := v.(json.Object); is_obj {
			return obj, true
		}
	}
	return nil, false
}

@(private = "file")
j_array :: proc(o: json.Object, key: string) -> (json.Array, bool) {
	if v, ok := o[key]; ok {
		if arr, is_arr := v.(json.Array); is_arr {
			return arr, true
		}
	}
	return nil, false
}

@(private = "file")
j_f32 :: proc(o: json.Object, key: string, def: f32 = 0) -> f32 {
	if v, ok := o[key]; ok {
		if x, is_int := v.(json.Integer); is_int {
			return f32(x)
		}
		if x, is_float := v.(json.Float); is_float {
			return f32(x)
		}
	}
	return def
}

@(private = "file")
j_i32 :: proc(o: json.Object, key: string, def: i32 = 0) -> i32 {
	if v, ok := o[key]; ok {
		if x, is_int := v.(json.Integer); is_int {
			return i32(x)
		}
		if x, is_float := v.(json.Float); is_float {
			return i32(x)
		}
	}
	return def
}

@(private = "file")
j_u32 :: proc(o: json.Object, key: string, def: u32 = 0) -> u32 {
	if v, ok := o[key]; ok {
		if x, is_int := v.(json.Integer); is_int {
			return x > 0 ? u32(x) : 0
		}
		if x, is_float := v.(json.Float); is_float {
			return f32_as_u32(f32(x))
		}
	}
	return def
}

@(private = "file")
j_bool :: proc(o: json.Object, key: string, def: bool = false) -> bool {
	if v, ok := o[key]; ok {
		if b, is_bool := v.(json.Boolean); is_bool {
			return bool(b)
		}
	}
	return def
}

@(private = "file")
j_string :: proc(o: json.Object, key: string, def: string = "") -> string {
	if v, ok := o[key]; ok {
		if s, is_str := v.(json.String); is_str {
			return string(s)
		}
	}
	return def
}

// j_i32_alias reads `key`, falling back to `alias` (used for editor versions that
// wrote the IK family id as "id" instead of "family_id").
@(private = "file")
j_i32_alias :: proc(o: json.Object, key, alias: string, def: i32 = 0) -> i32 {
	if _, ok := o[key]; ok {
		return j_i32(o, key, def)
	}
	return j_i32(o, alias, def)
}

@(private = "file")
j_vec2 :: proc(o: json.Object, key: string, def := Vec2{}) -> Vec2 {
	if obj, ok := j_object(o, key); ok {
		return {j_f32(obj, "x"), j_f32(obj, "y")}
	}
	return def
}

@(private = "file")
j_tint :: proc(o: json.Object, key: string, def: Tint) -> Tint {
	if obj, ok := j_object(o, key); ok {
		return {j_f32(obj, "r"), j_f32(obj, "g"), j_f32(obj, "b"), j_f32(obj, "a")}
	}
	return def
}

@(private = "file")
j_u32_array :: proc(o: json.Object, key: string) -> [dynamic]u32 {
	out: [dynamic]u32
	if arr, ok := j_array(o, key); ok {
		out = make([dynamic]u32, 0, len(arr))
		for i in 0 ..< len(arr) {
			if x, is_int := arr[i].(json.Integer); is_int {
				append(&out, x > 0 ? u32(x) : 0)
			}
		}
	}
	return out
}

@(private = "file")
parse_handle_preset :: proc(v: json.Value) -> HandlePreset {
	if s, ok := v.(json.String); ok {
		switch string(s) {
		case "Linear":
			return .Linear
		case "SineIn":
			return .SineIn
		case "SineOut":
			return .SineOut
		case "SineInOut":
			return .SineInOut
		case "None":
			return .None
		case "Custom":
			return .Custom
		}
	}
	if x, ok := v.(json.Integer); ok && x >= 0 && x <= 5 {
		return HandlePreset(i32(x))
	}
	return .Linear
}

@(private = "file")
parse_bone :: proc(o: json.Object) -> Bone {
	return {
		id = j_u32(o, "id"),
		name = j_string(o, "name"),
		parent_id = j_i32(o, "parent_id"),
		rot = j_f32(o, "rot"),
		scale = j_vec2(o, "scale"),
		pos = j_vec2(o, "pos"),
		hidden = j_bool(o, "hidden"),
		ik_family_id = j_i32(o, "ik_family_id"),
		visuals_id = j_i32(o, "visuals_id"),
		physics_id = j_i32(o, "physics_id"),
		init_rot = j_f32(o, "init_rot"),
		init_scale = j_vec2(o, "init_scale"),
		init_pos = j_vec2(o, "init_pos"),
		init_hidden = j_bool(o, "init_hidden"),
	}
}

@(private = "file")
parse_keyframe :: proc(o: json.Object) -> Keyframe {
	kf := Keyframe {
		frame        = j_u32(o, "frame"),
		bone_id      = j_u32(o, "bone_id"),
		element      = j_string(o, "element"),
		value        = j_f32(o, "value"),
		next_kf      = j_i32(o, "next_kf"),
		value_str    = j_string(o, "value_str"),
		start_handle = j_vec2(o, "start_handle"),
		end_handle   = j_vec2(o, "end_handle"),
		label_top    = j_f32(o, "label_top"),
	}
	if v, ok := o["handle_preset"]; ok {
		kf.handle_preset = parse_handle_preset(v)
	}
	return kf
}

@(private = "file")
parse_animation :: proc(o: json.Object) -> Animation {
	anim := Animation {
		name = j_string(o, "name"),
		fps  = j_u32(o, "fps"),
	}
	if arr, ok := j_array(o, "keyframes"); ok {
		anim.keyframes = make([dynamic]Keyframe, 0, len(arr))
		for i in 0 ..< len(arr) {
			if kf_obj, is_obj := arr[i].(json.Object); is_obj {
				append(&anim.keyframes, parse_keyframe(kf_obj))
			}
		}
	}
	return anim
}

@(private = "file")
parse_bone_bind :: proc(o: json.Object) -> BoneBind {
	bind := BoneBind {
		bone_id = j_i32(o, "bone_id"),
		is_path = j_bool(o, "is_path"),
	}
	if arr, ok := j_array(o, "verts"); ok {
		bind.verts = make([dynamic]BoneBindVert, 0, len(arr))
		for i in 0 ..< len(arr) {
			if v_obj, is_obj := arr[i].(json.Object); is_obj {
				append(&bind.verts, BoneBindVert{id = j_u32(v_obj, "id"), weight = j_f32(v_obj, "weight")})
			}
		}
	}
	return bind
}

@(private = "file")
parse_visuals :: proc(o: json.Object) -> Visuals {
	v := Visuals {
		tex         = j_string(o, "tex"),
		tint        = j_tint(o, "tint", default_tint()),
		zindex      = j_i32(o, "zindex"),
		pivot_pos   = j_vec2(o, "pivot_pos"),
		pivot_rot   = j_f32(o, "pivot_rot"),
		pivot_scale = j_vec2(o, "pivot_scale"),
		init_tex    = j_string(o, "init_tex"),
		init_zindex = j_i32(o, "init_zindex"),
		init_tint   = j_tint(o, "init_tint", default_tint()),
	}

	if arr, ok := j_array(o, "vertices"); ok {
		v.vertices = make([dynamic]Vertex, 0, len(arr))
		for i in 0 ..< len(arr) {
			if v_obj, is_obj := arr[i].(json.Object); is_obj {
				append(
					&v.vertices,
					Vertex {
						pos = j_vec2(v_obj, "pos"),
						uv = j_vec2(v_obj, "uv"),
						init_pos = j_vec2(v_obj, "init_pos"),
					},
				)
			}
		}
	}

	v.indices = j_u32_array(o, "indices")

	if arr, ok := j_array(o, "binds"); ok {
		v.binds = make([dynamic]BoneBind, 0, len(arr))
		for i in 0 ..< len(arr) {
			if b_obj, is_obj := arr[i].(json.Object); is_obj {
				append(&v.binds, parse_bone_bind(b_obj))
			}
		}
	}

	return v
}

@(private = "file")
parse_physics :: proc(o: json.Object) -> Physics {
	return {
		global_pos = j_vec2(o, "global_pos"),
		pos_damping = j_f32(o, "pos_damping"),
		pos_ratio = j_f32(o, "pos_ratio"),
		global_rot = j_f32(o, "global_rot"),
		global_orbit = j_f32(o, "global_orbit"),
		global_orbit_diff = j_f32(o, "global_orbit_diff"),
		global_orbit_vel = j_f32(o, "global_orbit_vel"),
		rot_damping = j_f32(o, "rot_damping"),
		rot_bounce = j_f32(o, "rot_bounce"),
		rot_vel = j_f32(o, "rot_vel"),
		sway = j_f32(o, "sway"),
		global_scale = j_vec2(o, "global_scale"),
		scale_damping = j_f32(o, "scale_damping"),
		scale_ratio = j_f32(o, "scale_ratio"),
	}
}

@(private = "file")
parse_inverse_kinematics :: proc(o: json.Object) -> InverseKinematics {
	return {
		family_id = j_i32_alias(o, "family_id", "id"),
		constraint = j_string(o, "constraint"),
		mode = j_string(o, "mode"),
		target_id = j_i32(o, "target_id"),
		bone_ids = j_u32_array(o, "bone_ids"),
		mimic_target = j_bool(o, "mimic_target"),
		init_constraint = j_string(o, "init_constraint"),
		init_mode = j_string(o, "init_mode"),
		init_mimic_target = j_bool(o, "init_mimic_target"),
	}
}

@(private = "file")
parse_texture :: proc(o: json.Object) -> Texture {
	return {
		offset = j_vec2(o, "offset"),
		size = j_vec2(o, "size"),
		name = j_string(o, "name"),
		atlas_idx = j_u32(o, "atlas_idx"),
	}
}

@(private = "file")
parse_style :: proc(o: json.Object) -> Style {
	s := Style {
		id     = j_u32(o, "id"),
		name   = j_string(o, "name"),
		active = j_bool(o, "active"),
	}
	if arr, ok := j_array(o, "textures"); ok {
		s.textures = make([dynamic]Texture, 0, len(arr))
		for i in 0 ..< len(arr) {
			if t_obj, is_obj := arr[i].(json.Object); is_obj {
				append(&s.textures, parse_texture(t_obj))
			}
		}
	}
	return s
}

@(private = "file")
parse_tex_atlas :: proc(o: json.Object) -> TexAtlas {
	return {filename = j_string(o, "filename"), size = j_vec2(o, "size")}
}

// armature_parse_json parses the `armature.json` payload of a `.skf` archive.
//
// Everything it allocates -- the JSON tree and the armature's arrays -- comes from
// the ambient `context.allocator`, so the matching destroys have to run under the
// same allocator.
//
// The returned `root` owns every string referenced by the armature, so it must
// stay alive for as long as the armature is used: free it with
// `json.destroy_value(root)` (after `armature_destroy`) when done.
armature_parse_json :: proc(data: []u8) -> (armature: Armature, root: json.Value, ok: bool) {
	v, err := json.parse_string(string(data), .JSON, true)
	if err != nil {
		return {}, nil, false
	}
	obj, is_obj := v.(json.Object)
	if !is_obj {
		json.destroy_value(v)
		return {}, nil, false
	}

	armature.baked_ik = j_bool(obj, "baked_ik")

	if arr, has := j_array(obj, "bones"); has {
		armature.bones = make([dynamic]Bone, 0, len(arr))
		for i in 0 ..< len(arr) {
			if o, is_o := arr[i].(json.Object); is_o {
				append(&armature.bones, parse_bone(o))
			}
		}
	}
	if arr, has := j_array(obj, "animations"); has {
		armature.animations = make([dynamic]Animation, 0, len(arr))
		for i in 0 ..< len(arr) {
			if o, is_o := arr[i].(json.Object); is_o {
				append(&armature.animations, parse_animation(o))
			}
		}
	}
	if arr, has := j_array(obj, "textures"); has {
		armature.textures = make([dynamic]Texture, 0, len(arr))
		for i in 0 ..< len(arr) {
			if o, is_o := arr[i].(json.Object); is_o {
				append(&armature.textures, parse_texture(o))
			}
		}
	}
	if arr, has := j_array(obj, "styles"); has {
		armature.styles = make([dynamic]Style, 0, len(arr))
		for i in 0 ..< len(arr) {
			if o, is_o := arr[i].(json.Object); is_o {
				append(&armature.styles, parse_style(o))
			}
		}
	}
	if arr, has := j_array(obj, "atlases"); has {
		armature.atlases = make([dynamic]TexAtlas, 0, len(arr))
		for i in 0 ..< len(arr) {
			if o, is_o := arr[i].(json.Object); is_o {
				append(&armature.atlases, parse_tex_atlas(o))
			}
		}
	}
	if arr, has := j_array(obj, "inverse_kinematics"); has {
		armature.inverse_kinematics = make([dynamic]InverseKinematics, 0, len(arr))
		for i in 0 ..< len(arr) {
			if o, is_o := arr[i].(json.Object); is_o {
				append(&armature.inverse_kinematics, parse_inverse_kinematics(o))
			}
		}
	}
	if arr, has := j_array(obj, "visuals"); has {
		armature.visuals = make([dynamic]Visuals, 0, len(arr))
		for i in 0 ..< len(arr) {
			if o, is_o := arr[i].(json.Object); is_o {
				append(&armature.visuals, parse_visuals(o))
			}
		}
	}
	if arr, has := j_array(obj, "physics"); has {
		armature.physics = make([dynamic]Physics, 0, len(arr))
		for i in 0 ..< len(arr) {
			if o, is_o := arr[i].(json.Object); is_o {
				append(&armature.physics, parse_physics(o))
			}
		}
	}

	return armature, v, true
}

// ---------------------------------------------------------------------------
// .skf archives
// ---------------------------------------------------------------------------

// SKF is a loaded `.skf` archive: the armature plus the raw PNG bytes of every
// atlas, in the same order as `skf.armature.atlases`.
SKF :: struct {
	armature: Armature,
	atlases:  [dynamic][]u8,

	// Owns the strings referenced by `armature`.
	root:     json.Value,
	has_root: bool,
}

// skf_load reads and parses a `.skf` file.
skf_load :: proc(path: string) -> (skf: SKF, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return {}, false
	}
	defer delete(data)
	return skf_load_from_memory(data)
}

// skf_load_from_memory parses an in-memory `.skf` archive.
skf_load_from_memory :: proc(data: []u8) -> (skf: SKF, ok: bool) {
	zip, zip_ok := zip_open(data)
	if !zip_ok {
		return {}, false
	}
	defer zip_close(&zip)

	json_data, found := zip_find(&zip, "armature.json")
	if !found {
		return {}, false
	}

	armature, root, parse_ok := armature_parse_json(json_data)
	if !parse_ok {
		return {}, false
	}

	skf.armature = armature
	skf.root = root
	skf.has_root = true

	// Copy the atlas bytes: they borrow the (possibly temporary) archive buffer.
	skf.atlases = make([dynamic][]u8, 0, len(armature.atlases))
	for i in 0 ..< len(armature.atlases) {
		atlas_data, atlas_found := zip_find(&zip, armature.atlases[i].filename)
		if !atlas_found {
			append(&skf.atlases, nil)
			continue
		}
		dup := make([]u8, len(atlas_data))
		copy(dup, atlas_data)
		append(&skf.atlases, dup)
	}

	return skf, true
}

// skf_destroy frees everything the archive owns, using the ambient
// `context.allocator` -- which must be the one `skf_load*` ran under.
skf_destroy :: proc(skf: ^SKF) {
	armature_destroy(&skf.armature)
	for i in 0 ..< len(skf.atlases) {
		if skf.atlases[i] != nil {
			delete(skf.atlases[i])
		}
	}
	delete(skf.atlases)
	if skf.has_root {
		json.destroy_value(skf.root)
	}
	skf^ = {}
}

// skf_find_entry copies a named entry out of an in-memory `.skf` archive (debug help).
skf_find_entry :: proc(data: []u8, name: string) -> (out: []u8, ok: bool) {
	zip, zip_ok := zip_open(data)
	if !zip_ok {
		return nil, false
	}
	defer zip_close(&zip)
	entry, found := zip_find(&zip, name)
	if !found {
		return nil, false
	}
	dup := make([]u8, len(entry))
	copy(dup, entry)
	return dup, true
}
