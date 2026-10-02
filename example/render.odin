// raylib rendering adapter for this example.
//
// `main.odin` owns the demo loop; this file owns everything raylib-specific:
// placing the constructed armature in screen space and drawing its deformed
// meshes / sprite quads. It mirrors `rusty_skelform_macroquad`, the reference
// engine integration for the Rust runtime.
//
// Coordinate note: SkelForm's armature space is Y-up; raylib's screen space is
// Y-down, so both bones and vertices are flipped on the Y axis (exactly like the
// macroquad runtime does).
package main

import "core:slice"

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

import skf ".."

// Construct_Options controls how the armature is placed on screen, matching
// `rusty_skelform_macroquad::ConstructOptions`.
Construct_Options :: struct {
	/// Added (in screen pixels) to every constructed bone and vertex.
	position: skf.Vec2,
	/// Multiplied into every constructed bone and vertex (use negative X to flip).
	scale:    skf.Vec2,
	/// Subtracted from physics positions to fake momentum.
	velocity: skf.Vec2,
}

DEFAULT_CONSTRUCT_OPTIONS :: Construct_Options {
	position = {0, 0},
	scale    = {1, 1},
	velocity = {0, 0},
}

// construct_with_options runs the SkelForm construction pipeline and then maps the
// result into raylib screen space, applying `options`.
construct_with_options :: proc(
	armature: ^skf.Armature,
	options: Construct_Options = DEFAULT_CONSTRUCT_OPTIONS,
) {
	skf.construct(armature)

	options_scale := options.scale
	options_position := options.position

	for b in 0 ..< len(armature.constructed_bones) {
		bone := &armature.constructed_bones[b]

		bone.pos.y = -bone.pos.y
		bone.rot = -bone.rot

		bone.scale = skf.vec2_mul(bone.scale, options_scale)
		bone.pos = skf.vec2_mul(bone.pos, options_scale)
		bone.pos = skf.vec2_add(bone.pos, options_position)

		// apply velocity, for physics
		if phys, ok := skf.get_physics(armature.physics[:], bone.physics_id); ok {
			phys.global_pos = skf.vec2_sub(phys.global_pos, options.velocity)
		}

		if skf.is_facing_left(options_scale) {
			bone.rot = -bone.rot
		}

		if visual, ok := skf.get_visuals(armature.visuals[:], bone.visuals_id); ok {
			for v in 0 ..< len(visual.vertices) {
				visual.vertices[v].pos.y = -visual.vertices[v].pos.y
				visual.vertices[v].pos = skf.vec2_mul(visual.vertices[v].pos, options_scale)
				visual.vertices[v].pos = skf.vec2_add(visual.vertices[v].pos, options_position)
			}
		}
	}
}

// draw_armature renders `armature.constructed_bones` (call `construct_with_options`
// first), selecting each bone's texture from `styles` exactly like the macroquad
// runtime: bones are drawn from the highest z-index to the lowest.
//
// `textures` must be indexed by `Texture.atlas_idx` (see `load_textures`).
draw_armature :: proc(armature: ^skf.Armature, textures: []rl.Texture2D, styles: []skf.Style) {
	bones := armature.constructed_bones[:]
	visuals := armature.visuals[:]

	// SkelForm meshes are flat artwork. Mapping armature space (Y up) onto the screen
	// (Y down) reverses their triangle winding, so culling would drop every triangle
	// of an unmirrored armature and keep only the mirrored one. Nothing else in this
	// example needs culling, so it stays off for the rest of the frame.
	rlgl.DisableBackfaceCulling()

	// Stable sort by z-index without mutating the caller's bone order.
	Z_Entry :: struct {
		zindex: i32,
		index:  int,
	}
	order := make([dynamic]Z_Entry, 0, len(bones))
	defer delete(order)

	for b in 0 ..< len(bones) {
		zindex := i32(0)
		if visual, ok := skf.get_visuals(visuals, bones[b].visuals_id); ok {
			zindex = visual.zindex
		}
		append(&order, Z_Entry{zindex = zindex, index = b})
	}
	slice.sort_by(order[:], proc(a, b: Z_Entry) -> bool {
		if a.zindex == b.zindex {
			return a.index < b.index
		}
		return a.zindex < b.zindex
	})

	for entry in order {
		bone := &bones[entry.index]
		if bone.hidden || bone.visuals_id == -1 {
			continue
		}

		visual, visual_ok := skf.get_visuals(visuals, bone.visuals_id)
		if !visual_ok {
			continue
		}

		// get this bone's texture (based on the active styles)
		tex, tex_ok := skf.get_bone_texture(visual.tex, styles)
		if !tex_ok {
			continue
		}

		atlas_idx := int(tex.atlas_idx)
		if atlas_idx < 0 || atlas_idx >= len(textures) {
			continue
		}
		atlas := textures[atlas_idx]

		color := rl.Color {
			u8(clamp01(visual.tint.r) * 255),
			u8(clamp01(visual.tint.g) * 255),
			u8(clamp01(visual.tint.b) * 255),
			u8(clamp01(visual.tint.a) * 255),
		}

		// will be used to flip pivot transforms if necessary
		is_left := skf.is_facing_left(bone.scale)
		dir: f32 = is_left ? 1.0 : -1.0

		// setup pivot
		//
		// The pivot offset lives in texture space (Y up, so `pivot_pos` is measured
		// against the unflipped sprite). Mapping it into screen space therefore has to
		// negate Y *before* rotating by the bone: `Rot(r) * Flip * (scale * p)`. The
		// macroquad runtime reaches the same result by rotating with `bone.rot * dir`
		// and negating afterwards, which only agrees for one of the two facing
		// directions -- with it the head and shoes jump across the body when the
		// armature is mirrored.
		pivot_pos := skf.vec2_mul(visual.pivot_pos, tex.size)
		pivot_pos = skf.vec2_mul(pivot_pos, bone.scale)
		pivot_pos.y = -pivot_pos.y
		pivot_pos = skf.vec2_mul(pivot_pos, visual.pivot_scale)
		pivot_pos = skf.rotate_vec2(pivot_pos, bone.rot)

		// render bone as mesh
		if len(visual.vertices) > 0 {
			draw_mesh(visual, tex, pivot_pos, atlas, color)
			continue
		}

		// A bone without an authored mesh still gets a textured quad, but it goes
		// through the same triangle path as the meshes: `DrawTexturePro` derives the
		// rotated corners from `dest.width`/`dest.height`, and mirroring the armature
		// makes `bone.scale.x` (hence `dest.width`) negative, which stops being a
		// clean mirror of the unmirrored pose.
		draw_sprite(bone, tex, pivot_pos, atlas, color, bone.rot + visual.pivot_rot*dir)
	}
}

BONE_COLOR        :: rl.Color{80, 140, 230, 210}
BONE_HIDDEN_COLOR :: rl.Color{220, 90, 90, 120}

// draw_bones overlays the skeleton: one line per bone-to-parent link plus a dot at
// every joint. Hidden bones are drawn in red so the hierarchy stays readable. Call
// it after `draw_armature`, on top of the sprites.
draw_bones :: proc(armature: ^skf.Armature) {
	bones := armature.constructed_bones[:]

	for b in 0 ..< len(bones) {
		bone := &bones[b]
		color := BONE_COLOR
		if bone.hidden {
			color = BONE_HIDDEN_COLOR
		}

		rl.DrawCircleV(rl.Vector2{bone.pos.x, bone.pos.y}, 3, color)

		parent := bone.parent_id
		if parent < 0 || int(parent) >= len(bones) {
			continue
		}
		rl.DrawLineV(
			rl.Vector2{bones[parent].pos.x, bones[parent].pos.y},
			rl.Vector2{bone.pos.x, bone.pos.y},
			color,
		)
	}
}

@(private = "file")
clamp01 :: proc(f: f32) -> f32 {
	if f < 0 {
		return 0
	}
	if f > 1 {
		return 1
	}
	return f
}

@(private = "file")
Atlas_UV :: struct {
	// Origin of the texture rect in normalized atlas coordinates, and the rect's
	// size in the same units.
	lt: skf.Vec2,
	rb: skf.Vec2,
}

@(private = "file")
atlas_uv :: proc(tex: skf.Texture, atlas: rl.Texture2D) -> (Atlas_UV, bool) {
	atlas_w := f32(atlas.width)
	atlas_h := f32(atlas.height)
	if atlas_w == 0 || atlas_h == 0 {
		return {}, false
	}
	return Atlas_UV{
		lt = {tex.offset.x / atlas_w, tex.offset.y / atlas_h},
		rb = {
			(tex.offset.x + tex.size.x) / atlas_w - tex.offset.x / atlas_w,
			(tex.offset.y + tex.size.y) / atlas_h - tex.offset.y / atlas_h,
		},
	}, true
}

@(private = "file")
draw_mesh :: proc(
	visual: ^skf.Visuals,
	tex: skf.Texture,
	pivot: skf.Vec2,
	atlas: rl.Texture2D,
	color: rl.Color,
) {
	uv, ok := atlas_uv(tex, atlas)
	if !ok {
		return
	}

	rlgl.SetTexture(atlas.id)
	// rlgl's vertex functions do not grow the render batch themselves: without this
	// call the vertices are silently dropped once the batch is full.
	rlgl.CheckRenderBatchLimit(i32(len(visual.indices)))
	rlgl.Begin(rlgl.TRIANGLES)
	for i := 0; i + 2 < len(visual.indices); i += 3 {
		for k in 0 ..< 3 {
			index := int(visual.indices[i + k])
			if index < 0 || index >= len(visual.vertices) {
				continue
			}
			vertex := visual.vertices[index]
			rlgl.Color4ub(color.r, color.g, color.b, color.a)
			rlgl.TexCoord2f(uv.lt.x + uv.rb.x * vertex.uv.x, uv.lt.y + uv.rb.y * vertex.uv.y)
			rlgl.Vertex2f(vertex.pos.x + pivot.x, vertex.pos.y + pivot.y)
		}
	}
	rlgl.End()
}

// draw_sprite renders a bone that has no authored mesh as the four-corner texture
// rect the editor gives it (`create_tex_rect`), mapped into screen space by the
// bone's own transform.
@(private = "file")
draw_sprite :: proc(
	bone: ^skf.Bone,
	tex: skf.Texture,
	pivot: skf.Vec2,
	atlas: rl.Texture2D,
	color: rl.Color,
	rot: f32,
) {
	uv, ok := atlas_uv(tex, atlas)
	if !ok {
		return
	}

	tx := tex.size.x / 2.0
	ty := tex.size.y / 2.0
	// Corners of the texture rect, and the UV each one samples.
	corners := [4]skf.Vec2{ {-tx, -ty}, {tx, -ty}, {tx, ty}, {-tx, ty} }
	corner_uv := [4]skf.Vec2{ {0, 0}, {1, 0}, {1, 1}, {0, 1} }
	triangles := [6]int{ 0, 1, 2, 0, 2, 3 }

	center := skf.vec2_add(bone.pos, pivot)

	rlgl.SetTexture(atlas.id)
	rlgl.CheckRenderBatchLimit(6)
	rlgl.Begin(rlgl.TRIANGLES)
	for i in triangles {
		pos := skf.vec2_mul(corners[i], bone.scale)
		pos = skf.rotate_vec2(pos, rot)
		pos = skf.vec2_add(pos, center)
		rlgl.Color4ub(color.r, color.g, color.b, color.a)
		rlgl.TexCoord2f(uv.lt.x + uv.rb.x * corner_uv[i].x, uv.lt.y + uv.rb.y * corner_uv[i].y)
		rlgl.Vertex2f(pos.x, pos.y)
	}
	rlgl.End()
}

// load_textures decodes the atlas PNGs of a loaded `.skf` archive into raylib
// textures. The result is indexed the same way as `Armature.atlases` and must be
// released with `unload_textures`.
load_textures :: proc(archive: ^skf.SKF) -> [dynamic]rl.Texture2D {
	textures := make([dynamic]rl.Texture2D, 0, len(archive.atlases))
	for i in 0 ..< len(archive.atlases) {
		png := archive.atlases[i]
		if png == nil {
			append(&textures, rl.Texture2D{})
			continue
		}
		image := rl.LoadImageFromMemory(".png", raw_data(png), i32(len(png)))
		defer rl.UnloadImage(image)
		append(&textures, rl.LoadTextureFromImage(image))
	}
	return textures
}

// unload_textures frees the textures returned by `load_textures`.
unload_textures :: proc(textures: ^[dynamic]rl.Texture2D) {
	for t in textures {
		rl.UnloadTexture(t)
	}
	delete(textures^)
}
