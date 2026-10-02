// SkelForm + raylib example.
//
// Loads a `.skf` armature, plays its animations, builds the skeleton and draws it
// with raylib using the Odin SkelForm runtime (see `..`).
//
// Run it from the repository root, or just double-click the built exe: the armature
// is looked up relative to the working directory *and* to the executable, so an exe
// living in `build/` still finds the armatures shipped in `example/`.
//
//	odin run example
//	odin run example -- example/skellina.skf
//	odin run example -- -frames 120 -hidden -stats   # smoke test, no window
//
// Controls: WASD to move, SPACE to cycle animations, 1..9 to wear a single costume,
// 0 to go back to the armature's active costume set, B to toggle the bone overlay,
// F12 to save a screenshot.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

import rl "vendor:raylib"

import skf ".."

DEFAULT_ARMATURE :: "example/skellington.skf"

main :: proc() {
	path := DEFAULT_ARMATURE
	max_frames := -1
	hidden := false
	stats := false
	static := false
	show_bones := false
	screenshot := ""
	direction: f32 = 1

	for i := 1; i < len(os.args); i += 1 {
		arg := os.args[i]
		switch {
		case arg == "-frames" && i + 1 < len(os.args):
			if value, parse_ok := strconv.parse_int(os.args[i + 1]); parse_ok {
				max_frames = value
			}
			i += 1
		case arg == "-screenshot" && i + 1 < len(os.args):
			screenshot = os.args[i + 1]
			i += 1
		case arg == "-hidden":
			hidden = true
		case arg == "-stats":
			stats = true
		case arg == "-static":
			static = true
		case arg == "-bones":
			show_bones = true
		case arg == "-left":
			direction = -1
		case !strings.has_prefix(arg, "-"):
			path = arg
		}
	}

	resolved, found := find_armature(path)
	if !found {
		fmt.eprintln("skelform: failed to load", path)
		show_error_window(path)
		os.exit(1)
	}
	path = resolved

	archive, load_ok := skf.skf_load(path)
	if !load_ok {
		fmt.eprintln("skelform: failed to load", path)
		show_error_window(path)
		os.exit(1)
	}
	defer skf.skf_destroy(&archive)

	armature := &archive.armature
	fmt.printfln(
		"skelform: loaded %v: %v bones, %v animations, %v visuals, %v IK families, %v atlases, %v styles",
		path,
		len(armature.bones),
		len(armature.animations),
		len(armature.visuals),
		len(armature.inverse_kinematics),
		len(armature.atlases),
		len(armature.styles),
	)
	if len(armature.bones) == 0 {
		fmt.eprintln("skelform: the armature has no bones")
		show_error_window(path)
		os.exit(1)
	}

	if hidden {
		rl.SetConfigFlags({.WINDOW_HIDDEN})
	}
	rl.InitWindow(900, 700, "SkelForm - Odin + raylib")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	textures := load_textures(&archive)
	defer unload_textures(&textures)

	// Only the worn costume may be used for texture lookups: each style provides the
	// texture rects of one costume, and a 1x1 rect hides a part for that costume.
	// Number keys pick a single style, 0 restores the armature's own selection.
	active_styles := skf.active_styles(armature)
	defer delete(active_styles)

	single_style: [1]skf.Style
	styles := active_styles
	style_label := "active"

	// Play one animation at a time (the runtime supports several in parallel).
	anims := make([]skf.Animation, 1)
	defer delete(anims)
	frames := make([]u32, 1)
	defer delete(frames)
	smooth_frames := make([]u32, 1)
	defer delete(smooth_frames)
	smooth_frames[0] = 20

	anim_idx := 0
	position := skf.Vec2{450, 400}
	previous_position := position
	animation_start := time.now()

	frame_count := 0
	for !rl.WindowShouldClose() {
		// --- input ---------------------------------------------------------
		if rl.IsKeyDown(.A) {
			position.x -= 4
			direction = -1
		}
		if rl.IsKeyDown(.D) {
			position.x += 4
			direction = 1
		}
		if rl.IsKeyDown(.W) {
			position.y -= 4
		}
		if rl.IsKeyDown(.S) {
			position.y += 4
		}
		if len(armature.animations) > 0 && rl.IsKeyPressed(.SPACE) {
			anim_idx = (anim_idx + 1) % len(armature.animations)
			animation_start = time.now()
		}
		for i in 0 ..< min(len(armature.styles), 9) {
			if rl.IsKeyPressed(rl.KeyboardKey(int(rl.KeyboardKey.ONE) + i)) {
				single_style[0] = armature.styles[i]
				styles = single_style[:]
				style_label = fmt.tprintf("style %v (%v)", i, armature.styles[i].name)
			}
		}
		if rl.IsKeyPressed(.ZERO) {
			styles = active_styles
			style_label = "active"
		}
		if rl.IsKeyPressed(.B) {
			show_bones = !show_bones
		}

		// --- animate -------------------------------------------------------
		elapsed := f32(time.duration_seconds(time.since(animation_start)))
		if !static && len(armature.animations) > 0 {
			anims[0] = armature.animations[anim_idx]
			frames[0] = skf.time_frame(elapsed, &anims[0], false, true)
			skf.animate(
				&armature.bones,
				&armature.inverse_kinematics,
				&armature.visuals,
				anims,
				frames,
				smooth_frames,
			)
		}

		// --- construct + draw ----------------------------------------------
		velocity := skf.vec2_scale(skf.vec2_sub(position, previous_position), 10)
		construct_with_options(
			armature,
			{position = position, scale = {0.2 * direction, 0.2}, velocity = velocity},
		)

		rl.BeginDrawing()
		rl.ClearBackground(rl.RAYWHITE)
		draw_armature(armature, textures[:], styles)
		if show_bones {
			draw_bones(armature)
		}
		rl.DrawText(
			"WASD move   SPACE animation   1..9 style   0 auto   B bones   F12 screenshot",
			10,
			10,
			20,
			rl.DARKGRAY,
		)
		if len(armature.animations) > 0 {
			label := fmt.ctprintf(
				"animation %v/%v: %v (frame %v)   costume: %v",
				anim_idx + 1,
				len(armature.animations),
				armature.animations[anim_idx].name,
				frames[0],
				style_label,
			)
			rl.DrawText(label, 10, 34, 20, rl.DARKGRAY)
		}

		// F12 (or the last frame of a `-frames` run) writes a screenshot of this frame.
		// NOTE: the frame buffer has to be read *after* EndDrawing; raylib's
		// `TakeScreenshot` reads the swapped, already-cleared buffer and saves a blank PNG.
		capture :=
			screenshot != "" && (rl.IsKeyPressed(.F12) || (max_frames > 0 && frame_count + 1 >= max_frames))
		rl.EndDrawing()

		if capture {
			image := rl.LoadImageFromScreen()
			if rl.ExportImage(image, fmt.ctprintf("%v", screenshot)) {
				fmt.printfln("skelform: screenshot written to %v", screenshot)
			} else {
				fmt.eprintln("skelform: failed to write screenshot", screenshot)
			}
			rl.UnloadImage(image)
		}

		// Optional proof that the armature actually rendered: compare the frame
		// buffer against the clear color on the last frame.
		if stats && max_frames > 0 && frame_count + 1 >= max_frames {
			image := rl.LoadImageFromScreen()
			colors := rl.LoadImageColors(image)
			total := int(image.width) * int(image.height)
			non_background := 0
			for i in 0 ..< total {
				c := colors[i]
				if c.r != rl.RAYWHITE.r || c.g != rl.RAYWHITE.g || c.b != rl.RAYWHITE.b {
					non_background += 1
				}
			}
			fmt.printfln(
				"skelform: %v / %v pixels differ from the clear color (%.1f%%)",
				non_background,
				total,
				f32(non_background) / f32(total) * 100,
			)
			if non_background == 0 {
				fmt.eprintln("skelform: nothing was drawn")
				os.exit(1)
			}
			rl.UnloadImageColors(colors)
			rl.UnloadImage(image)
		}

		previous_position = position
		frame_count += 1
		if max_frames > 0 && frame_count >= max_frames {
			break
		}
	}

	if len(armature.constructed_bones) == 0 {
		fmt.eprintln("skelform: no constructed bones were produced")
		os.exit(1)
	}
	fmt.printfln(
		"skelform: ok, drew %v frames, %v constructed bones",
		frame_count,
		len(armature.constructed_bones),
	)
}

// find_armature resolves `given` against the working directory first, then walks up
// from the executable's directory, trying both the full relative path and just its
// file name. That makes a double-clicked exe (whose working directory is its own
// folder) find armatures sitting next to it as well as the ones shipped in the
// repository's `example/` folder.
find_armature :: proc(given: string) -> (path: string, found: bool) {
	if os.exists(given) {
		return given, true
	}

	directory, dir_err := os.get_executable_directory(context.allocator)
	if dir_err != nil {
		return given, false
	}

	base := filepath.base(given)
	for _ in 0 ..< 6 {
		if candidate, ok := join_if_file(directory, given); ok {
			return candidate, true
		}
		if candidate, ok := join_if_file(directory, base); ok {
			return candidate, true
		}
		parent := filepath.dir(directory)
		if len(parent) == 0 || parent == directory {
			break
		}
		directory = parent
	}

	return given, false
}

@(private = "file")
join_if_file :: proc(directory, name: string) -> (path: string, found: bool) {
	candidate, join_err := filepath.join({directory, name})
	if join_err != nil {
		return "", false
	}
	if os.exists(candidate) {
		return candidate, true
	}
	delete(candidate)
	return "", false
}

// show_error_window keeps a window on screen when the armature cannot be loaded, so a
// double-clicked exe does not just flash a console and vanish.
show_error_window :: proc(message: string) {
	rl.InitWindow(780, 210, "SkelForm - could not load armature")
	defer rl.CloseWindow()
	rl.SetTargetFPS(30)

	for !rl.WindowShouldClose() {
		rl.BeginDrawing()
		rl.ClearBackground(rl.RAYWHITE)
		rl.DrawText("Could not load the SkelForm armature", 20, 22, 22, rl.MAROON)
		rl.DrawText(fmt.ctprintf("path: %v", message), 20, 60, 18, rl.DARKGRAY)
		rl.DrawText(
			"Usage: example.exe [armature.skf] [-frames N] [-hidden] [-stats]",
			20,
			108,
			16,
			rl.DARKGRAY,
		)
		rl.DrawText(
			"       [-static] [-bones] [-left] [-screenshot file.png]",
			20,
			132,
			16,
			rl.GRAY,
		)
		rl.DrawText(
			"Shipped armatures: example/skellington.skf, example/skellina.skf (repo root)",
			20,
			132,
			16,
			rl.GRAY,
		)
		rl.EndDrawing()
	}
}
