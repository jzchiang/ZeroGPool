extends Node3D
## Volume Pool (Godot 4.2+): 36 balls (cue + 35) floating in a glass box with 12 pockets.
##
## Pockets: the 8 corners + the midpoints of the 4 long edges (the 3D version of a 6-pocket table).
## Rack: a 5-layer tetrahedron (15+10+6+3+1 = 35 balls). Ball 35 is the black ball, buried in the center.
## Groups: solids 1-17, stripes 18-34, black 35.
##
## Controls
##   Hold LMB and drag DOWN  = pull the cue back (power). Release = shoot. Esc = cancel.
##   Right-drag / A,D,W,S    = aim (relative to the screen; Shift = fine)
##   Ctrl+Right-drag / MMB   = orbit camera       Wheel = zoom
##   F = camera behind the aim line   T = aim at nearest ball (press again for the next one)
##   Ball pad / Arrow keys   = cue tip position (spin).  C / double-click = center
##   R = restart.  Ball in hand: move mouse, wheel changes height, click to place.

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

enum State { PLACING, AIMING, MOVING, GAME_OVER }

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

## HUD control that draws the potted balls.
class Tray extends Control:
	var nums: Array[int] = []
	var colors: Array = []
	func _draw() -> void:
		for i in nums.size():
			_ball(Vector2(12 + i * 26, 14), nums[i], 10.0)
	func _ball(p: Vector2, num: int, rad: float) -> void:
		var cream := Color(0.96, 0.96, 0.92)
		var col: Color = colors[num]
		if num < 18 or num == 35:
			draw_circle(p, rad, col)
		else:
			draw_circle(p, rad, cream)
			var a := asin(0.55)
			var pts := PackedVector2Array()
			for k in 9:
				var ang := lerpf(-a, a, k / 8.0)
				pts.append(p + Vector2(cos(ang), sin(ang)) * rad)
			for k in 9:
				var ang := lerpf(PI - a, PI + a, k / 8.0)
				pts.append(p + Vector2(cos(ang), sin(ang)) * rad)
			draw_colored_polygon(pts, col)
		draw_circle(p, rad * 0.55, cream)
		draw_string(ThemeDB.fallback_font, p + Vector2(-rad, rad * 0.3), str(num),
			HORIZONTAL_ALIGNMENT_CENTER, rad * 2.0, int(rad * 0.8), Color.BLACK)

## Cue-ball face: click / drag to choose the strike point. x = right, y = top.
class SpinPad extends Control:
	signal changed(v: Vector2)
	var offset := Vector2.ZERO
	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
				if mb.double_click:
					changed.emit(Vector2.ZERO)
				else:
					_set_from(mb.position)
		elif event is InputEventMouseMotion:
			var mm := event as InputEventMouseMotion
			if (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
				_set_from(mm.position)
	func _set_from(p: Vector2) -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 6.0
		var v := Vector2((p.x - c.x) / r, -(p.y - c.y) / r)
		if v.length() > 1.0:
			v = v.normalized()
		changed.emit(v)
	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 6.0
		draw_circle(c, r + 5.0, Color(0, 0, 0, 0.55))
		draw_circle(c, r, Color(0.96, 0.96, 0.92))
		draw_line(c + Vector2(-r, 0), c + Vector2(r, 0), Color(0, 0, 0, 0.25), 1.0)
		draw_line(c + Vector2(0, -r), c + Vector2(0, r), Color(0, 0, 0, 0.25), 1.0)
		draw_arc(c, r, 0.0, TAU, 48, Color.BLACK, 2.0)
		var dot := c + Vector2(offset.x, -offset.y) * r
		draw_circle(dot, 7.0, Color(0.85, 0.1, 0.1))
		draw_arc(dot, 7.0, 0.0, TAU, 20, Color.WHITE, 1.5)

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
var place_y := 0.0
var player := 0
var groups := [-1, -1]        # -1 open, 0 solids, 1 stripes
var message := ""
var winner := -1
var first_hit := -1
var potted_this_shot: Array[int] = []
var potted_tray: Array[int] = []
var cue_potted := false
var shooter_on_black := false

# ---- camera
var cam: Camera3D
var view_yaw := -PI / 2.0
var view_pitch := 0.38
var zoom := 1.0
var cam_target := Vector3.ZERO
var cam_yaw := -PI / 2.0
var cam_pitch := 0.38
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
var drop_line: MeshInstance3D
var hud: CanvasLayer
var status_label: Label
var msg_label: Label
var over_label: Label
var power_bar: ProgressBar
var tray: Tray
var spin_pad: SpinPad
var spin_label: Label


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
	build_hud()
	cam = Camera3D.new()
	cam.fov = 55.0
	cam.near = 0.02
	cam.far = 60.0
	add_child(cam)
	cam.make_current()
	new_game()
	cam_target = cue.pos
	cam_yaw = view_yaw
	cam_pitch = view_pitch
	cam_dist = 0.9


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
	env.background_color = Color(0.04, 0.045, 0.06)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.78, 0.9)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.light_energy = 0.5
	add_child(sun)

	var lamp := SpotLight3D.new()
	lamp.position = Vector3(0, 2.6, 0)
	lamp.rotation_degrees = Vector3(-90, 0, 0)
	lamp.spot_range = 6.0
	lamp.spot_angle = 50.0
	lamp.light_energy = 3.0
	lamp.shadow_enabled = true
	add_child(lamp)

	var ground := PlaneMesh.new()
	ground.size = Vector2(16, 16)
	ground.material = mat(Color(0.1, 0.1, 0.13), 0.9)
	var gi := MeshInstance3D.new()
	gi.mesh = ground
	gi.position = Vector3(0, -1.3, 0)
	add_child(gi)

func build_volume() -> void:
	# floor (felt) so ball shadows give a sense of depth
	add_box(Vector3(W + 0.04, 0.02, D + 0.04), Vector3(0, -HALF.y - 0.011, 0), mat(Color(0.05, 0.4, 0.22), 0.95))
	# pedestal
	add_box(Vector3(W * 0.5, 0.35, D * 0.5), Vector3(0, -HALF.y - 0.2, 0), mat(Color(0.2, 0.1, 0.05), 0.5))

	# glass walls
	var gm := mat(Color(0.7, 0.85, 1.0, 0.06))
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	gm.cull_mode = BaseMaterial3D.CULL_DISABLED
	add_box(Vector3(W, H, D), Vector3.ZERO, gm, false)

	# 12 frame edges
	var frame := mat(Color(0.62, 0.5, 0.22), 0.35)
	frame.metallic = 0.7
	var t := 0.024
	var sg: Array[float] = [-1.0, 1.0]
	for a in sg:
		for b in sg:
			add_box(Vector3(W + t, t, t), Vector3(0, a * HALF.y, b * HALF.z), frame)
			add_box(Vector3(t, H + t, t), Vector3(a * HALF.x, 0, b * HALF.z), frame)
			add_box(Vector3(t, t, D + t), Vector3(a * HALF.x, b * HALF.y, 0), frame)

	# 12 pockets: dark cups plus a faint halo that shows the capture zone
	var cup := mat(Color(0.02, 0.02, 0.02), 0.3)
	var halo := unshaded(Color(0.6, 0.85, 1.0, 0.07))
	for pk in pockets:
		add_sphere(POCKET_R - R, pk, cup)
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
	drop_line = make_line()
	(drop_line.mesh as BoxMesh).material = unshaded(Color(1, 1, 1, 0.5))
	drop_line.visible = false
	add_child(drop_line)

func make_label(text_size: int, pos: Vector2, width := 0.0) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", text_size)
	l.add_theme_color_override("font_color", Color.WHITE)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 6)
	if width > 0.0:
		l.custom_minimum_size = Vector2(width, 0)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hud.add_child(l)
	return l

func build_hud() -> void:
	hud = CanvasLayer.new()
	add_child(hud)
	status_label = make_label(26, Vector2(24, 14))
	msg_label = make_label(16, Vector2(24, 52), 900.0)
	msg_label.add_theme_color_override("font_color", Color(1, 0.95, 0.6))
	var pl := make_label(14, Vector2(1000, 8))
	pl.text = "Power (hold LMB, drag down)"
	power_bar = ProgressBar.new()
	power_bar.position = Vector2(1000, 32)
	power_bar.custom_minimum_size = Vector2(250, 20)
	power_bar.min_value = 0.0
	power_bar.max_value = 1.0
	power_bar.show_percentage = false
	hud.add_child(power_bar)
	over_label = make_label(56, Vector2(0, 280), 1280.0)
	over_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	over_label.visible = false
	tray = Tray.new()
	tray.position = Vector2(24, 622)
	tray.colors = ball_colors
	tray.nums = potted_tray
	hud.add_child(tray)

	spin_label = make_label(14, Vector2(1112, 528))
	spin_label.text = "Cue tip (C = center)"
	spin_pad = SpinPad.new()
	spin_pad.position = Vector2(1140, 556)
	spin_pad.custom_minimum_size = Vector2(112, 112)
	spin_pad.size = Vector2(112, 112)
	spin_pad.changed.connect(_on_spin_changed)
	hud.add_child(spin_pad)

	var hint := make_label(13, Vector2(24, 662), 1080.0)
	hint.text = "LMB hold + drag down: power, release to shoot (Esc cancels)   Right-drag / A,D,W,S: aim   Ctrl+Right-drag / MMB: orbit   Wheel: zoom   F: view behind aim   T: target nearest ball   Arrows / pad: spin   R: restart"
	hint.modulate = Color(1, 1, 1, 0.65)

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
	var o := (-aim_dir + Vector3.UP * 0.4).normalized()
	view_yaw = atan2(o.x, o.z)
	view_pitch = asin(clampf(o.y, -0.99, 0.99))

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
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo:
			match k.keycode:
				KEY_R: new_game()
				KEY_C: spin = Vector2.ZERO
				KEY_F:
					if state == State.AIMING:
						snap_view()
				KEY_T:
					if state == State.AIMING:
						target_nearest(true)
				KEY_ESCAPE:
					charging = false
					power = 0.0
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
						place_y = clampf(place_y + 0.03, LO.y, HI.y)
					else:
						zoom = clampf(zoom * 0.92, 0.35, 2.5)
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					if state == State.PLACING:
						place_y = clampf(place_y - 0.03, LO.y, HI.y)
					else:
						zoom = clampf(zoom / 0.92, 0.35, 2.5)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if charging:
			power = clampf((mm.position.y - drag_start.y) / DRAG_RANGE, 0.0, 1.0)
		var right_down := (mm.button_mask & MOUSE_BUTTON_MASK_RIGHT) != 0
		var orbit := (mm.button_mask & MOUSE_BUTTON_MASK_MIDDLE) != 0 or (right_down and Input.is_key_pressed(KEY_CTRL))
		if orbit:
			view_yaw -= mm.relative.x * 0.005
			view_pitch = clampf(view_pitch + mm.relative.y * 0.005, -1.45, 1.45)
		elif right_down and state == State.AIMING:
			var s := 0.2 if Input.is_key_pressed(KEY_SHIFT) else 1.0
			rotate_aim(-mm.relative.x * 0.003 * s, -mm.relative.y * 0.003 * s)

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
		message = "Press R to play again."
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
		place_y = clampf(cue.pos.y, LO.y, HI.y)
		view_yaw = 0.0
		view_pitch = 0.45
		if cue.potted:
			cue.potted = false
			if cue.tween:
				cue.tween.kill()
			cue.node.show()
			place_y = 0.0
		cue.vel = Vector3.ZERO
		cue.w = Vector3.ZERO
		message = "Foul (%s). Player %d has ball in hand: move the mouse, wheel = height, click to place." % [reason, player + 1]
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
		var mp := get_viewport().get_mouse_position()
		var o := cam.project_ray_origin(mp)
		var n := cam.project_ray_normal(mp)
		if absf(n.y) > 0.05:
			var t := (place_y - o.y) / n.y
			if t > 0.0:
				cue.pos = (o + n * t).clamp(LO, HI)

	sync_balls(delta)
	update_camera(delta)
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
	cam_pitch = lerpf(cam_pitch, view_pitch, k)
	cam_yaw = lerp_angle(cam_yaw, view_yaw, k)
	var off := Vector3(sin(cam_yaw) * cos(cam_pitch), sin(cam_pitch), cos(cam_yaw) * cos(cam_pitch)) * cam_dist
	cam.position = cam_target + off
	cam.look_at(cam_target, Vector3.UP)

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
	drop_line.visible = state == State.PLACING
	if state == State.PLACING:
		place_line(drop_line, cue.pos, Vector3(cue.pos.x, -HALF.y, cue.pos.z), 0.003)
	if state != State.AIMING: return

	var d := aim_dir
	var info := aim_trace(cue.pos, d)
	var t: float = info["t"]
	var hit: Ball = info["ball"]
	var end := cue.pos + d * t
	place_line(aim_line, cue.pos, end, 0.004)
	ghost.position = end
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
	status_label.text = "Player %d  (%s)" % [player + 1, grp]
	msg_label.text = message
	power_bar.value = power
	over_label.visible = state == State.GAME_OVER
	if state == State.GAME_OVER:
		over_label.text = "Player %d wins!" % (winner + 1)
	spin_pad.visible = state == State.AIMING
	spin_label.visible = state == State.AIMING
	spin_pad.offset = spin
	spin_pad.queue_redraw()
	tray.queue_redraw()
