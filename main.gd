extends Node3D
## Zero-G Pool (Godot 4.2+): 36 balls (cue + 35) floating in a glass box with 12 pockets.
##
## Pockets: the 8 corners + the midpoints of the 4 long edges (the 3D version of a 6-pocket table).
## Rack: a 5-layer tetrahedron (15+10+6+3+1 = 35 balls). Ball 35 is the black ball, buried in the center.
## Groups: solids 1-17, stripes 18-34, black 35.
##
## Controls
##   Hold LMB and drag DOWN  = pull the cue back (power). Release = shoot. Esc = cancel.
##   Right-drag / A,D,W,S    = aim (relative to the screen; Shift = fine)
##   Ctrl+Right-drag / MMB   = orbit (free trackball, no fixed up)   Q/E = roll   Wheel = zoom
##   1-6 or click the orientation cube = view from +X -X +Y -Y +Z -Z   L = level the horizon
##   F = camera behind the aim line   T = aim at nearest ball (press again for the next one)
##   Ball pad / Arrow keys   = cue tip position (spin).  C / double-click = center
##   M / Esc = menu.   R = restart.  Ball in hand: move mouse, wheel changes depth, click to place.

# ---- volume (meters, centered on the origin)
const W := 1.8          # x (long axis)
const H := 0.9          # y (up)
const D := 0.9          # z
const HALF := Vector3(W / 2.0, H / 2.0, D / 2.0)
const R := 0.0286
const LO := Vector3(-W / 2.0 + R, -H / 2.0 + R, -D / 2.0 + R)   # ball-center limits
const HI := Vector3(W / 2.0 - R, H / 2.0 - R, D / 2.0 - R)
const POCKET_R := 0.12
const POCKET_PULL := 0.8        # gentle suction near pockets (0 = off). 3D pockets are hard to hit.
const PULL_RANGE := 0.26
const BLACK := 35

# ---- physics
const SUBSTEPS := 8
const MAX_SPEED := 6.0
const DRAG := 1.4               # the "air": exponential slowdown (1/s)
const FRICTION := 0.1           # constant slowdown (m/s^2) so balls come to rest
const SPIN_DECAY := 1.0
const MAGNUS := 0.0025          # spin curves the ball: a = MAGNUS * (spin x velocity)
const WALL_BOUNCE := 0.85
const WALL_FRICTION := 0.3      # walls grip spin
const BALL_BOUNCE := 0.96
const BALL_FRICTION := 0.08     # ball-to-ball throw
const STOP_SPEED := 0.02
const DRAG_RANGE := 260.0       # px of mouse drag for full power
const MAX_TIP_OFFSET := 0.5     # fraction of R

const DIGITS := ["111101101101111", "010110010010111", "111001111100111", "111001111001111",
	"101101111001001", "111100111001111", "111100111101111", "111001001001001",
	"111101111101111", "111101111001111"]

enum State { MENU, PLACING, AIMING, MOVING, GAME_OVER }

class Ball:
	var pos: Vector3
	var vel := Vector3.ZERO
	var w := Vector3.ZERO     # angular velocity
	var num: int
	var idx := 0
	var potted := false
	var node: MeshInstance3D
	var tween: Tween
	func _init(n: int, p: Vector3) -> void:
		num = n
		pos = p

var ball_colors: Array[Color] = []

# ---- game state
var balls: Array[Ball] = []
var cue: Ball
var pockets := PackedVector3Array()
var state := State.AIMING
var power := 0.0
var spin := Vector2.ZERO
var charging := false
var drag_start := Vector2.ZERO
var aim_dir := Vector3.RIGHT
var target_idx := 0
var place_depth := 2.6      # ball-in-hand: distance from the camera along its view axis
var player := 0
var groups := [-1, -1]        # -1 open, 0 solids, 1 stripes
var message := ""
var winner := -1
var first_hit := -1
var potted_this_shot: Array[int] = []
var potted_tray: Array[int] = []
var cue_potted := false
var shooter_on_black := false

# ---- camera: a free trackball. Orientation is a quaternion, so there is no fixed "up".
var cam: Camera3D
var view_q := Quaternion(Basis(Vector3.UP, -PI / 2.0))   # desired orientation
var cam_q := Quaternion(Basis(Vector3.UP, -PI / 2.0))    # smoothed orientation actually shown
var zoom := 1.0
var cam_target := Vector3.ZERO
var cam_dist := 1.0

# ---- visuals / hud
var aim_root: Node3D
var aim_line: MeshInstance3D
var target_line: MeshInstance3D
var ghost: MeshInstance3D
var target_hl: MeshInstance3D
var stick: MeshInstance3D
var spin_dot: MeshInstance3D
var invalid_marker: MeshInstance3D
var guides_cue: Array[MeshInstance3D] = []
var guides_ghost: Array[MeshInstance3D] = []
var gizmo_box: SubViewportContainer
var gizmo_cam: Camera3D
var game_ui: GameUI
var game_started := false
var state_before_menu := State.AIMING


func _ready() -> void:
	# 8 corners + midpoints of the 4 long (x) edges = 12 pockets
	var sx: Array[float] = [-1.0, 1.0]
	for x in sx:
		for y in sx:
			for z in sx:
				pockets.append(Vector3(x * HALF.x, y * HALF.y, z * HALF.z))
	for y in sx:
		for z in sx:
			pockets.append(Vector3(0.0, y * HALF.y, z * HALF.z))
	build_palette()
	build_environment()
	build_volume()
	build_aim_nodes()
	game_ui = GameUI.new()
	game_ui.ball_colors = ball_colors
	add_child(game_ui)
	game_ui.spin_changed.connect(_on_spin_changed)
	game_ui.play_requested.connect(_on_play)
	game_ui.resume_requested.connect(_on_resume)
	game_ui.quit_requested.connect(_on_quit)
	build_gizmo()
	cam = Camera3D.new()
	cam.fov = 55.0
	cam.near = 0.02
	cam.far = 60.0
	add_child(cam)
	cam.make_current()
	# lights ride on the camera, so the lighting never says which way is "down"
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-25, -25, 0)
	key.light_energy = 1.0
	cam.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(20, 140, 0)
	fill.light_energy = 0.35
	cam.add_child(fill)
	new_game()
	cam_q = view_q
	cam_target = Vector3.ZERO
	cam_dist = 2.8
	open_menu()


# ================================================================ scene building
func mat(c: Color, rough := 0.8) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m

func unshaded(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if c.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m

func no_shadow(mi: GeometryInstance3D) -> void:
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func add_box(size: Vector3, pos: Vector3, m: Material, shadow := true) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	mi.position = pos
	if not shadow:
		no_shadow(mi)
	add_child(mi)
	return mi

func add_sphere(radius: float, pos: Vector3, m: Material, shadow := true) -> MeshInstance3D:
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = 2.0 * radius
	sm.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = sm
	mi.position = pos
	if not shadow:
		no_shadow(mi)
	add_child(mi)
	return mi

func build_palette() -> void:
	ball_colors.clear()
	ball_colors.append(Color(0.96, 0.96, 0.92))   # 0 = cue ball
	var base: Array[Color] = []
	for i in 17:
		var h := fmod(i * 0.381966, 1.0)
		var s := 0.9 if i % 2 == 0 else 0.6
		var v := 0.95 if i % 3 != 0 else 0.75
		base.append(Color.from_hsv(h, s, v))
	for n in range(1, 35):
		ball_colors.append(base[(n - 1) % 17])    # solids 1-17 and stripes 18-34 share the palette
	ball_colors.append(Color(0.04, 0.04, 0.04))   # 35 = black

func build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.03, 0.035, 0.05)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.8, 0.82, 0.95)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

func build_volume() -> void:
	# Six identical glass faces carrying a faint grid (aligned to world space, 15 cm cells).
	var img := Image.create(64, 64, true, Image.FORMAT_RGBA8)
	img.fill(Color(0.6, 0.8, 1.0, 0.035))
	img.fill_rect(Rect2i(0, 0, 64, 2), Color(0.65, 0.85, 1.0, 0.30))
	img.fill_rect(Rect2i(0, 0, 2, 64), Color(0.65, 0.85, 1.0, 0.30))
	img.generate_mipmaps()
	var gm := StandardMaterial3D.new()
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	gm.cull_mode = BaseMaterial3D.CULL_DISABLED
	gm.albedo_texture = ImageTexture.create_from_image(img)
	gm.uv1_triplanar = true
	gm.uv1_world_triplanar = true
	gm.uv1_scale = Vector3.ONE / 0.15
	add_box(Vector3(W, H, D), Vector3.ZERO, gm, false)

	# 12 frame edges, colored by axis: X red, Y green, Z blue
	var cx := unshaded(Color(0.95, 0.3, 0.3))
	var cy := unshaded(Color(0.35, 0.9, 0.4))
	var cz := unshaded(Color(0.35, 0.55, 1.0))
	var t := 0.024
	var sg: Array[float] = [-1.0, 1.0]
	for a in sg:
		for b in sg:
			add_box(Vector3(W + t, t, t), Vector3(0, a * HALF.y, b * HALF.z), cx, false)
			add_box(Vector3(t, H + t, t), Vector3(a * HALF.x, 0, b * HALF.z), cy, false)
			add_box(Vector3(t, t, D + t), Vector3(a * HALF.x, b * HALF.y, 0), cz, false)

	# 12 pockets: dark cups plus a faint halo that shows the capture zone
	var cup := mat(Color(0.02, 0.02, 0.02), 0.3)
	var halo := unshaded(Color(0.6, 0.85, 1.0, 0.07))
	for pk in pockets:
		add_sphere(POCKET_R - R, pk, cup, false)
		add_sphere(POCKET_R, pk, halo, false)

func make_line() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.material = unshaded(Color.WHITE)
	mi.mesh = bm
	no_shadow(mi)
	return mi

func build_aim_nodes() -> void:
	aim_root = Node3D.new()
	add_child(aim_root)
	aim_line = make_line()
	(aim_line.mesh as BoxMesh).material = unshaded(Color(1, 1, 1, 0.6))
	aim_root.add_child(aim_line)
	target_line = make_line()
	(target_line.mesh as BoxMesh).material = unshaded(Color(1, 0.9, 0.3, 0.9))
	aim_root.add_child(target_line)

	ghost = add_sphere(R, Vector3.ZERO, unshaded(Color(1, 1, 1, 0.3)), false)
	remove_child(ghost)
	aim_root.add_child(ghost)
	target_hl = add_sphere(R * 1.3, Vector3.ZERO, unshaded(Color(1, 0.9, 0.2, 0.25)), false)
	remove_child(target_hl)
	aim_root.add_child(target_hl)
	spin_dot = add_sphere(0.004, Vector3.ZERO, unshaded(Color(0.95, 0.1, 0.1)), false)
	remove_child(spin_dot)
	aim_root.add_child(spin_dot)

	var cm := CylinderMesh.new()
	cm.top_radius = 0.014
	cm.bottom_radius = 0.006
	cm.height = 1.4
	cm.material = mat(Color(0.8, 0.6, 0.32), 0.4)
	stick = MeshInstance3D.new()
	stick.mesh = cm
	no_shadow(stick)
	aim_root.add_child(stick)

	invalid_marker = add_sphere(R * 1.3, Vector3.ZERO, unshaded(Color(1, 0.15, 0.15, 0.45)), false)
	invalid_marker.visible = false

	# depth guides: thin axis-colored lines from a ball to the nearest wall on each axis
	guides_cue = make_guides()
	guides_ghost = make_guides()

func make_guides() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var cols: Array[Color] = [Color(0.95, 0.3, 0.3, 0.55), Color(0.35, 0.9, 0.4, 0.55), Color(0.35, 0.55, 1.0, 0.55)]
	for i in 3:
		var ln := make_line()
		(ln.mesh as BoxMesh).material = unshaded(cols[i])
		ln.visible = false
		add_child(ln)
		out.append(ln)
	return out

func update_guides(lines: Array[MeshInstance3D], p: Vector3, show_them: bool) -> void:
	for i in 3:
		lines[i].visible = false
	if not show_them: return
	for ax in 3:
		var wall := p
		wall[ax] = HALF[ax] if p[ax] >= 0.0 else -HALF[ax]
		place_line(lines[ax], p, wall, 0.0025)

func _on_spin_changed(v: Vector2) -> void:
	spin = v


# ================================================================ balls
func spot(img: Image, cx: int, cy: int, r: int, col: Color) -> void:
	for y in range(cy - r, cy + r + 1):
		for x in range(cx - r, cx + r + 1):
			if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r:
				img.set_pixel(x, y, col)

func draw_number(img: Image, cx: int, cy: int, num: int) -> void:
	var s := str(num)
	var cell := 6
	var w := s.length() * 3 * cell + (s.length() - 1) * cell
	var x0 := cx - int(w * 0.5)
	var y0 := cy - int(2.5 * cell)
	for i in s.length():
		var bits: String = DIGITS[int(s[i])]
		for k in 15:
			if bits[k] == "1":
				var gx := k % 3
				var gy := int(k / 3.0)
				img.fill_rect(Rect2i(x0 + i * 4 * cell + gx * cell, y0 + gy * cell, cell, cell), Color.BLACK)

func make_ball_texture(num: int) -> ImageTexture:
	var img := Image.create(512, 256, true, Image.FORMAT_RGBA8)
	var white := Color(0.96, 0.96, 0.92)
	if num == 0:
		img.fill(white)
		spot(img, 128, 128, 7, Color(0.8, 0.1, 0.1))
		spot(img, 384, 128, 7, Color(0.8, 0.1, 0.1))
	else:
		var col := ball_colors[num]
		if num < 18 or num == BLACK:
			img.fill(col)
		else:
			img.fill(white)
			img.fill_rect(Rect2i(0, 70, 512, 116), col)
		spot(img, 128, 128, 30, white)
		spot(img, 384, 128, 30, white)
		draw_number(img, 128, 128, num)
		draw_number(img, 384, 128, num)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

func add_ball(num: int, p: Vector3) -> Ball:
	var b := Ball.new(num, p)
	var sm := SphereMesh.new()
	sm.radius = R
	sm.height = 2.0 * R
	sm.radial_segments = 40
	sm.rings = 20
	var m := StandardMaterial3D.new()
	m.albedo_texture = make_ball_texture(num)
	m.roughness = 0.15
	m.metallic_specular = 0.8
	sm.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = sm
	mi.position = p
	mi.basis = Basis.from_euler(Vector3(randf() * TAU, randf() * TAU, randf() * TAU))
	add_child(mi)
	b.node = mi
	b.idx = balls.size()
	balls.append(b)
	return b


# ================================================================ game setup
func new_game() -> void:
	for b in balls:
		if b.tween:
			b.tween.kill()
		b.node.queue_free()
	balls.clear()
	potted_tray.clear()
	groups = [-1, -1]
	player = 0
	winner = -1
	power = 0.0
	spin = Vector2.ZERO
	charging = false
	zoom = 1.0
	cue = add_ball(0, Vector3(-W * 0.3, 0.0, 0.0))

	# 35-ball tetrahedron: layer L (0..4) is a triangle with L+1 balls per side.
	# The apex (1 ball) faces the cue ball; the 15-ball base is at the back.
	var nums: Array = range(1, 35)
	nums.shuffle()
	var sp := 2.0 * R + 0.0004
	var dx := sqrt(2.0 / 3.0) * sp
	var apex_x := W * 0.14
	var i := 0
	for layer in 5:
		var n := layer + 1
		for row in n:
			for col in n - row:
				var lz := col * sp + row * sp * 0.5 - (n - 1) * sp * 0.5
				var ly := row * sp * 0.8660254 - (n - 1) * sp * 0.8660254 / 3.0
				var p := Vector3(apex_x + layer * dx, ly, lz)
				if layer == 3 and row == 1 and col == 1:
					add_ball(BLACK, p)       # the single interior ball = center of the rack
				else:
					add_ball(nums[i], p)
					i += 1
	state = State.AIMING
	message = "Player 1 breaks. Hold LMB and drag down to pull the cue back, release to shoot."
	target_nearest(false)


# ================================================================ helpers
func group_of(n: int) -> int:
	if n == 0: return -1
	if n == BLACK: return 2
	return 0 if n <= 17 else 1

func remaining(g: int) -> int:
	var c := 0
	for b in balls:
		if not b.potted and b.num != 0 and group_of(b.num) == g:
			c += 1
	return c

func any_moving() -> bool:
	for b in balls:
		if not b.potted and b.vel != Vector3.ZERO:
			return true
	return false

func placement_valid(p: Vector3) -> bool:
	if p.x < LO.x or p.y < LO.y or p.z < LO.z or p.x > HI.x or p.y > HI.y or p.z > HI.z:
		return false
	for pk in pockets:
		if p.distance_to(pk) < POCKET_R + R: return false
	for b in balls:
		if b != cue and not b.potted and b.pos.distance_to(p) < 2.0 * R + 0.002:
			return false
	return true

## Basis whose x = shooter's right, y = shooter's up, z = backwards (-aim).
func shot_basis(d: Vector3) -> Basis:
	var ref := Vector3.UP if absf(d.y) < 0.99 else Vector3.RIGHT
	var right := d.cross(ref).normalized()
	var up := right.cross(d).normalized()
	return Basis(right, up, -d)

func snap_view() -> void:
	# Turn the camera to look along the aim line from behind, keeping its current roll.
	var b := Basis(view_q)
	var f := -b.z
	var q: Quaternion
	if f.dot(aim_dir) < -0.9999:
		q = Quaternion(b.y.normalized(), PI)
	else:
		q = Quaternion(f, aim_dir)
	var nb := Basis(q) * b
	# lift the camera a little in its own frame so the shot line is not seen end-on
	nb = Basis(nb.x.normalized(), -0.35) * nb
	view_q = Quaternion(nb.orthonormalized()).normalized()

func orbit_view(dx: float, dy: float) -> void:
	# trackball: rotate about the camera's own up and right axes, so there are no poles
	var b := Basis(view_q)
	var r := Basis(b.y.normalized(), -dx * 0.005) * Basis(b.x.normalized(), -dy * 0.005)
	view_q = Quaternion((r * b).orthonormalized()).normalized()

func roll_view(angle: float) -> void:
	var b := Basis(view_q)
	view_q = Quaternion((Basis(b.z.normalized(), angle) * b).orthonormalized()).normalized()

func level_view() -> void:
	# put the world's +Y back on top of the screen (keeps the current look direction)
	var f := -Basis(view_q).z
	if absf(f.dot(Vector3.UP)) > 0.999: return
	var right := f.cross(Vector3.UP).normalized()
	var up := right.cross(f).normalized()
	view_q = Quaternion(Basis(right, up, -f))

func snap_axis(a: Vector3) -> void:
	# view from the +a side; of the 4 axis-aligned "up" choices, use the one closest to the current up
	var cur_up := Basis(view_q).y
	var axes: Array[Vector3] = [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]
	var best := Vector3.UP
	var best_d := -2.0
	for c in axes:
		if absf(c.dot(a)) > 0.5: continue
		var dd := c.dot(cur_up)
		if dd > best_d:
			best_d = dd
			best = c
	view_q = Quaternion(Basis(best.cross(a), best, a))

func target_nearest(next: bool) -> void:
	var cands: Array[Ball] = []
	for b in balls:
		if b != cue and not b.potted:
			cands.append(b)
	if cands.is_empty(): return
	cands.sort_custom(func(x: Ball, y: Ball) -> bool:
		return x.pos.distance_squared_to(cue.pos) < y.pos.distance_squared_to(cue.pos))
	if next:
		target_idx = (target_idx + 1) % cands.size()
	else:
		target_idx = 0
	aim_dir = (cands[target_idx].pos - cue.pos).normalized()
	snap_view()

func rotate_aim(dyaw: float, dpitch: float) -> void:
	var cb := cam.global_transform.basis
	aim_dir = aim_dir.rotated(cb.y.normalized(), dyaw).rotated(cb.x.normalized(), dpitch).normalized()


# ================================================================ input
func _unhandled_input(event: InputEvent) -> void:
	if state == State.MENU:
		if event is InputEventKey:
			var mk := event as InputEventKey
			if mk.pressed and not mk.echo:
				match mk.keycode:
					KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
						if not game_ui.help_visible:
							if game_started:
								_on_resume()
							else:
								_on_play()
					KEY_ESCAPE:
						if game_ui.help_visible:
							_on_help_back()
						elif game_started:
							_on_resume()
		return
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo:
			match k.keycode:
				KEY_R: new_game()
				KEY_C: spin = Vector2.ZERO
				KEY_L: level_view()
				KEY_1, KEY_KP_1: snap_axis(Vector3.RIGHT)
				KEY_2, KEY_KP_2: snap_axis(Vector3.LEFT)
				KEY_3, KEY_KP_3: snap_axis(Vector3.UP)
				KEY_4, KEY_KP_4: snap_axis(Vector3.DOWN)
				KEY_5, KEY_KP_5: snap_axis(Vector3.BACK)
				KEY_6, KEY_KP_6: snap_axis(Vector3.FORWARD)
				KEY_F:
					if state == State.AIMING:
						snap_view()
				KEY_T:
					if state == State.AIMING:
						target_nearest(true)
				KEY_ESCAPE:
					if charging:
						charging = false
						power = 0.0
					else:
						open_menu()
				KEY_M:
					open_menu()
				KEY_SPACE, KEY_ENTER:
					if state == State.PLACING:
						confirm_placement()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					if state == State.PLACING:
						confirm_placement()
					elif state == State.AIMING:
						charging = true
						drag_start = mb.position
						power = 0.0
				elif charging:
					charging = false
					if power >= 0.05 and state == State.AIMING:
						shoot()
					else:
						power = 0.0
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					if state == State.PLACING:
						place_depth = clampf(place_depth - 0.05, 0.3, 6.0)
					else:
						zoom = clampf(zoom * 0.92, 0.35, 2.5)
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					if state == State.PLACING:
						place_depth = clampf(place_depth + 0.05, 0.3, 6.0)
					else:
						zoom = clampf(zoom / 0.92, 0.35, 2.5)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if charging:
			power = clampf((mm.position.y - drag_start.y) / DRAG_RANGE, 0.0, 1.0)
		var right_down := (mm.button_mask & MOUSE_BUTTON_MASK_RIGHT) != 0
		var orbit := (mm.button_mask & MOUSE_BUTTON_MASK_MIDDLE) != 0 or (right_down and Input.is_key_pressed(KEY_CTRL))
		if orbit:
			orbit_view(mm.relative.x, mm.relative.y)
		elif right_down and state == State.AIMING:
			var sc := 0.2 if Input.is_key_pressed(KEY_SHIFT) else 1.0
			rotate_aim(-mm.relative.x * 0.003 * sc, -mm.relative.y * 0.003 * sc)

func confirm_placement() -> void:
	if placement_valid(cue.pos):
		state = State.AIMING
		power = 0.0
		message = "Player %d: aim and shoot." % (player + 1)
		target_nearest(false)

func shoot() -> void:
	var d := aim_dir
	var v0 := power * MAX_SPEED
	var sb := shot_basis(d)
	var a := spin.x * MAX_TIP_OFFSET   # + = right of center
	var b := spin.y * MAX_TIP_OFFSET   # + = above center
	cue.vel = d * v0
	# off-center hit: omega = 2.5 * v0 / R * (a * up - b * right)
	cue.w = (sb.y * a - sb.x * b) * (2.5 * v0 / R)
	first_hit = -1
	potted_this_shot.clear()
	cue_potted = false
	shooter_on_black = groups[player] != -1 and remaining(groups[player]) == 0
	state = State.MOVING
	message = ""
	spin = Vector2.ZERO


# ================================================================ physics
func _physics_process(delta: float) -> void:
	if state != State.MOVING: return
	var dt := delta / SUBSTEPS
	for s in SUBSTEPS:
		step(dt)
	if not any_moving():
		end_shot()

func wall_bounce(b: Ball, n: Vector3) -> void:
	# n = inward normal of the wall. The wall grips the ball's spin (english, follow, draw).
	var vn := b.vel.dot(n)
	if vn >= 0.0: return
	var vt := b.vel - n * vn
	var s := vt - R * b.w.cross(n)
	var jmax := WALL_FRICTION * (1.0 + WALL_BOUNCE) * -vn
	var jt := -s / 3.5
	if jt.length() > jmax:
		jt = jt.normalized() * jmax
	b.vel = n * (-WALL_BOUNCE * vn) + vt + jt
	b.w += n.cross(jt) * (-2.5 / R)

func step(dt: float) -> void:
	for b in balls:
		if b.potted: continue
		if b.vel == Vector3.ZERO: continue
		# spin curves the ball (Magnus effect)
		b.vel += MAGNUS * b.w.cross(b.vel) * dt
		# soft pull into nearby pockets
		for pk in pockets:
			var to := pk - b.pos
			var dist := to.length()
			if dist < PULL_RANGE and dist > 0.0001:
				b.vel += to / dist * POCKET_PULL * (1.0 - dist / PULL_RANGE) * dt
		b.pos += b.vel * dt
		var sp := b.vel.length()
		var ns := maxf(0.0, sp - FRICTION * dt) * (1.0 - DRAG * dt)
		if ns < STOP_SPEED:
			b.vel = Vector3.ZERO
			b.w = Vector3.ZERO
		else:
			b.vel = b.vel / sp * ns
			b.w *= (1.0 - SPIN_DECAY * dt)

		for pk in pockets:
			if b.pos.distance_to(pk) < POCKET_R:
				pot(b, pk)
				break
		if b.potted: continue

		var p := b.pos
		for ax in 3:
			var n := Vector3.ZERO
			if p[ax] < LO[ax]:
				p[ax] = LO[ax]
				n[ax] = 1.0
				b.pos = p
				wall_bounce(b, n)
			elif p[ax] > HI[ax]:
				p[ax] = HI[ax]
				n[ax] = -1.0
				b.pos = p
				wall_bounce(b, n)

	# ball-ball collisions (only pairs involving at least one moving ball)
	var moving: Array[Ball] = []
	for b in balls:
		if not b.potted and b.vel != Vector3.ZERO:
			moving.append(b)
	for a in moving:
		for c in balls:
			if c == a or c.potted: continue
			if c.idx < a.idx and c.vel != Vector3.ZERO: continue
			var d := c.pos - a.pos
			var d2 := d.length_squared()
			if d2 >= 4.0 * R * R or d2 < 1e-10: continue
			var dist := sqrt(d2)
			var n := d / dist
			var overlap := 2.0 * R - dist
			a.pos -= n * overlap * 0.5
			c.pos += n * overlap * 0.5
			var rel_v := a.vel - c.vel
			var rel := rel_v.dot(n)
			if rel > 0.0:
				var imp := rel * (1.0 + BALL_BOUNCE) * 0.5
				a.vel -= n * imp
				c.vel += n * imp
				# contact friction: throw and spin transfer
				var vt := rel_v - n * rel
				var s := vt + R * (a.w + c.w).cross(n)
				var f := -s / 7.0
				var fmax := BALL_FRICTION * imp
				if f.length() > fmax:
					f = f.normalized() * fmax
				a.vel += f
				c.vel -= f
				var dw := n.cross(f) * (2.5 / R)
				a.w += dw
				c.w += dw
				if first_hit < 0 and (a == cue or c == cue):
					first_hit = c.num if a == cue else a.num

func pot(b: Ball, pk: Vector3) -> void:
	b.potted = true
	b.vel = Vector3.ZERO
	b.w = Vector3.ZERO
	if b == cue:
		cue_potted = true
	else:
		potted_this_shot.append(b.num)
		potted_tray.append(b.num)
	if b.tween:
		b.tween.kill()
	b.tween = create_tween()
	b.tween.tween_property(b.node, "position", pk, 0.3)
	b.tween.tween_callback(b.node.hide)


# ================================================================ rules
func end_shot() -> void:
	var cur := player
	var other := 1 - player
	var foul := false
	var reason := ""
	power = 0.0

	if cue_potted:
		foul = true
		reason = "scratch"
	elif first_hit < 0:
		foul = true
		reason = "no ball hit"
	elif shooter_on_black:
		if first_hit != BLACK:
			foul = true
			reason = "must hit the black ball first"
	elif groups[cur] != -1:
		if group_of(first_hit) != groups[cur]:
			foul = true
			reason = "wrong ball hit first"
	elif first_hit == BLACK:
		foul = true
		reason = "hit the black ball first"

	if potted_this_shot.has(BLACK):
		winner = cur if (shooter_on_black and not foul) else other
		state = State.GAME_OVER
		message = "Press R to play again, or M for the menu."
		return

	if groups[cur] == -1 and not foul:
		for n in potted_this_shot:
			groups[cur] = group_of(n)
			groups[other] = 1 - groups[cur]
			break

	var potted_own := false
	for n in potted_this_shot:
		if groups[cur] != -1 and group_of(n) == groups[cur]:
			potted_own = true

	if foul:
		player = other
		state = State.PLACING
		place_depth = 2.6 * zoom
		if cue.potted:
			cue.potted = false
			if cue.tween:
				cue.tween.kill()
			cue.node.show()
		cue.vel = Vector3.ZERO
		cue.w = Vector3.ZERO
		message = "Foul (%s). Player %d has ball in hand: move the mouse, wheel = depth, click to place." % [reason, player + 1]
	else:
		if potted_own:
			message = "Nice shot! Player %d shoots again." % (player + 1)
		else:
			player = other
			message = "Player %d's turn." % (player + 1)
		state = State.AIMING
		target_nearest(false)


# ================================================================ per-frame
func _process(delta: float) -> void:
	if state == State.MENU:
		orbit_view(24.0 * delta, 0.0)   # slow cinematic orbit behind the menu
	else:
		var roll := 0.0
		if Input.is_key_pressed(KEY_Q): roll -= 1.0
		if Input.is_key_pressed(KEY_E): roll += 1.0
		if roll != 0.0:
			roll_view(roll * delta * 1.2)

	if state == State.AIMING:
		var slow := 0.25 if Input.is_key_pressed(KEY_SHIFT) else 1.0
		var yaw := 0.0
		var pitch := 0.0
		if Input.is_key_pressed(KEY_A): yaw += 1.0
		if Input.is_key_pressed(KEY_D): yaw -= 1.0
		if Input.is_key_pressed(KEY_W): pitch += 1.0
		if Input.is_key_pressed(KEY_S): pitch -= 1.0
		if yaw != 0.0 or pitch != 0.0:
			rotate_aim(yaw * delta * slow, pitch * delta * slow)
		var sv := Vector2.ZERO
		if Input.is_key_pressed(KEY_UP): sv.y += 1.0
		if Input.is_key_pressed(KEY_DOWN): sv.y -= 1.0
		if Input.is_key_pressed(KEY_RIGHT): sv.x += 1.0
		if Input.is_key_pressed(KEY_LEFT): sv.x -= 1.0
		if sv != Vector2.ZERO:
			spin = (spin + sv * delta * 1.2).limit_length(1.0)

	if state == State.PLACING:
		# the cue ball follows the mouse on a plane facing the camera; the wheel moves that plane in depth
		var mp := get_viewport().get_mouse_position()
		var o := cam.project_ray_origin(mp)
		var n := cam.project_ray_normal(mp)
		var denom := n.dot(-cam.global_transform.basis.z)
		if denom > 0.05:
			cue.pos = (o + n * (place_depth / denom)).clamp(LO, HI)

	sync_balls(delta)
	update_camera(delta)
	update_gizmo()
	update_aim()
	update_hud()

func sync_balls(delta: float) -> void:
	for b in balls:
		if b.potted: continue
		b.node.position = b.pos
		var ang := b.w.length() * delta
		if ang > 1e-6:
			b.node.basis = (Basis(b.w.normalized(), ang) * b.node.basis).orthonormalized()

func update_camera(delta: float) -> void:
	var d_target := Vector3.ZERO
	var d_dist := 2.8 * zoom
	match state:
		State.AIMING:
			d_target = cue.pos
			d_dist = 0.9 * zoom
		State.PLACING:
			d_dist = 2.6 * zoom
	var k := 1.0 - exp(-8.0 * delta)
	cam_target = cam_target.lerp(d_target, k)
	cam_dist = lerpf(cam_dist, d_dist, k)
	cam_q = cam_q.slerp(view_q, k).normalized()
	var b := Basis(cam_q)
	cam.global_transform = Transform3D(b, cam_target + b.z * cam_dist)

func place_line(node: MeshInstance3D, a: Vector3, b: Vector3, w: float) -> void:
	var d := b - a
	var l := d.length()
	node.visible = l > 0.002
	if l <= 0.002: return
	var dn := d / l
	var ref := Vector3.UP if absf(dn.y) < 0.99 else Vector3.RIGHT
	(node.mesh as BoxMesh).size = Vector3(w, w, l)
	node.global_transform = Transform3D(Basis.looking_at(dn, ref), (a + b) * 0.5)

func update_aim() -> void:
	aim_root.visible = state == State.AIMING
	invalid_marker.visible = state == State.PLACING and not placement_valid(cue.pos)
	invalid_marker.position = cue.pos
	update_guides(guides_cue, cue.pos, state == State.AIMING or state == State.PLACING)
	if state != State.AIMING:
		update_guides(guides_ghost, Vector3.ZERO, false)
		return

	var d := aim_dir
	var info := aim_trace(cue.pos, d)
	var t: float = info["t"]
	var hit: Ball = info["ball"]
	var end := cue.pos + d * t
	place_line(aim_line, cue.pos, end, 0.004)
	ghost.position = end
	update_guides(guides_ghost, end, true)
	target_hl.visible = hit != null
	if hit != null:
		target_hl.position = hit.pos
		var n := (hit.pos - end).normalized()
		place_line(target_line, hit.pos, hit.pos + n * 0.3, 0.004)
	else:
		target_line.visible = false

	# strike point on the cue ball (red dot) and the cue stick aimed at it
	var sb := shot_basis(d)
	var a := spin.x * MAX_TIP_OFFSET
	var b := spin.y * MAX_TIP_OFFSET
	var fwd := sqrt(maxf(0.0, 1.0 - a * a - b * b))
	var strike := cue.pos + (-d * fwd + sb.x * a + sb.y * b) * R
	spin_dot.position = strike
	var pull := 0.01 + power * 0.30
	var tip := strike - d * pull
	stick.global_transform = Transform3D(Basis(sb.x, -d, -sb.y), tip - d * 0.7)

func aim_trace(origin: Vector3, dir: Vector3) -> Dictionary:
	var best := INF
	var hit: Ball = null
	for b in balls:
		if b == cue or b.potted: continue
		var oc := origin - b.pos
		var bq := oc.dot(dir)
		var cq := oc.length_squared() - 4.0 * R * R
		var disc := bq * bq - cq
		if disc < 0.0: continue
		var t := -bq - sqrt(disc)
		if t > 0.0 and t < best:
			best = t
			hit = b
	var tr := INF
	for ax in 3:
		if dir[ax] > 1e-6:
			tr = minf(tr, (HI[ax] - origin[ax]) / dir[ax])
		elif dir[ax] < -1e-6:
			tr = minf(tr, (LO[ax] - origin[ax]) / dir[ax])
	if tr < best:
		best = tr
		hit = null
	return {"t": best, "ball": hit}

func update_hud() -> void:
	var grp := "open table"
	if groups[player] == 0: grp = "solids 1-17"
	elif groups[player] == 1: grp = "stripes 18-34"
	if groups[player] != -1 and remaining(groups[player]) == 0: grp = "black ball"
	var game_over_text := "Player %d wins!" % (winner + 1) if state == State.GAME_OVER else ""
	game_ui.update_hud("Player %d  (%s)" % [player + 1, grp], message, power,
		game_over_text, state == State.AIMING, spin, potted_tray, state != State.MENU)


func open_menu() -> void:
	if state == State.MENU: return
	state_before_menu = state
	state = State.MENU
	charging = false
	power = 0.0
	zoom = 1.0
	game_ui.open_menu(game_started)

func _on_play() -> void:
	if game_started:
		new_game()
	game_started = true
	game_ui.hide_menu()
	state = State.AIMING
	snap_view()

func _on_resume() -> void:
	game_ui.hide_menu()
	state = state_before_menu
	if state == State.AIMING:
		snap_view()

func _on_help_back() -> void:
	game_ui.show_menu_options()

func _on_quit() -> void:
	get_tree().quit()


# ================================================================ orientation gizmo
func build_gizmo() -> void:
	# A small cube in the corner that mirrors the camera orientation. Click a face to snap to that view.
	gizmo_box = SubViewportContainer.new()
	gizmo_box.stretch = true
	gizmo_box.position = Vector2(20, 140)
	gizmo_box.custom_minimum_size = Vector2(140, 140)
	gizmo_box.size = Vector2(140, 140)
	gizmo_box.gui_input.connect(_on_gizmo_input)
	game_ui.hud_layer.add_child(gizmo_box)

	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.msaa_3d = Viewport.MSAA_4X
	gizmo_box.add_child(vp)

	gizmo_cam = Camera3D.new()
	gizmo_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	gizmo_cam.size = 2.3
	gizmo_cam.near = 0.1
	gizmo_cam.far = 20.0
	vp.add_child(gizmo_cam)

	var axes: Array[Vector3] = [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]
	var names: Array[String] = ["+X", "-X", "+Y", "-Y", "+Z", "-Z"]
	var cols: Array[Color] = [
		Color(0.95, 0.3, 0.3), Color(0.55, 0.15, 0.15),
		Color(0.35, 0.85, 0.4), Color(0.15, 0.45, 0.2),
		Color(0.35, 0.55, 1.0), Color(0.18, 0.28, 0.6)]
	for i in 6:
		var a := axes[i]
		var up_hint := Vector3.UP
		if absf(a.y) > 0.5:
			up_hint = Vector3.FORWARD if a.y > 0.0 else Vector3.BACK
		var fb := Basis(up_hint.cross(a), up_hint, a)
		var qm := QuadMesh.new()
		qm.size = Vector2(1.2, 1.2)
		qm.material = unshaded(cols[i])
		var face := MeshInstance3D.new()
		face.mesh = qm
		face.transform = Transform3D(fb, a * 0.6)
		vp.add_child(face)
		var lab := Label3D.new()
		lab.text = names[i]
		lab.font_size = 96
		lab.pixel_size = 0.0045
		lab.outline_size = 14
		lab.shaded = false
		lab.double_sided = false
		lab.transform = Transform3D(fb, a * 0.61)
		vp.add_child(lab)

	var cap := game_ui.make_label(12, Vector2(20, 284))
	cap.text = "Click a face or press 1-6"

func update_gizmo() -> void:
	if gizmo_cam == null: return
	var b := Basis(cam_q)
	gizmo_cam.global_transform = Transform3D(b, b.z * 5.0)

func _on_gizmo_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton): return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed: return
	var o := gizmo_cam.project_ray_origin(mb.position)
	var n := gizmo_cam.project_ray_normal(mb.position)
	# ray vs the gizmo cube (half size 0.6)
	var tmin := -INF
	var tmax := INF
	for ax in 3:
		if absf(n[ax]) < 1e-6: continue
		var t1 := (-0.6 - o[ax]) / n[ax]
		var t2 := (0.6 - o[ax]) / n[ax]
		tmin = maxf(tmin, minf(t1, t2))
		tmax = minf(tmax, maxf(t1, t2))
	if tmax < tmin: return
	var hit := o + n * tmin
	var best := 0
	var bv := 0.0
	for ax in 3:
		if absf(hit[ax]) > bv:
			bv = absf(hit[ax])
			best = ax
	var a := Vector3.ZERO
	a[best] = signf(hit[best])
	snap_axis(a)
