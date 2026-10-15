extends Node3D
## 3D 8-ball pool for Godot 4.2+.
## Physics runs on the table plane (x, z) using simple circle collisions; everything is built in code.
## Controls: Right-drag / Left,Right / A,D = aim | Shift = fine aim | Wheel = zoom
##           Up,Down / W,S = power | Click / Space = shoot | R = restart

# ---- table (meters, table centered on the origin, felt surface at y = 0)
const TW := 2.54
const TH := 1.27
const TABLE := Rect2(-TW / 2.0, -TH / 2.0, TW, TH)
const R := 0.0286
const POCKET_R := 0.068
const SUBSTEPS := 10
const MAX_SPEED := 5.0
const FRICTION := 0.5
const DAMPING := 0.25
const CUSHION_BOUNCE := 0.78
const BALL_BOUNCE := 0.96
const STOP_SPEED := 0.02

const DIGITS := ["111101101101111", "010110010010111", "111001111100111", "111001111001111",
	"101101111001001", "111100111001111", "111100111101111", "111001001001001",
	"111101111101111", "111101111001111"]

enum State { PLACING, AIMING, MOVING, GAME_OVER }

class Ball:
	var pos: Vector2
	var last_pos: Vector2
	var vel := Vector2.ZERO
	var num: int
	var potted := false
	var node: MeshInstance3D
	var tween: Tween
	func _init(n: int, p: Vector2) -> void:
		num = n
		pos = p
		last_pos = p

## Small HUD control that draws the potted balls.
class Tray extends Control:
	var nums: Array[int] = []
	var colors: Array = []
	func _draw() -> void:
		for i in nums.size():
			_ball(Vector2(14 + i * 28, 16), nums[i], 11.0)
	func _ball(p: Vector2, num: int, rad: float) -> void:
		var cream := Color(0.96, 0.96, 0.92)
		var col: Color = colors[num if num <= 8 else num - 8]
		if num <= 8:
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
		draw_circle(p, rad * 0.5, cream)
		draw_string(ThemeDB.fallback_font, p + Vector2(-rad, rad * 0.32), str(num),
			HORIZONTAL_ALIGNMENT_CENTER, rad * 2.0, int(rad * 0.9), Color.BLACK)

var ball_colors := [
	Color(0.96, 0.96, 0.92),
	Color(0.95, 0.77, 0.0),   # 1 yellow
	Color(0.1, 0.3, 0.8),     # 2 blue
	Color(0.85, 0.12, 0.1),   # 3 red
	Color(0.4, 0.15, 0.6),    # 4 purple
	Color(0.95, 0.5, 0.05),   # 5 orange
	Color(0.05, 0.5, 0.2),    # 6 green
	Color(0.5, 0.08, 0.1),    # 7 maroon
	Color(0.04, 0.04, 0.04),  # 8 black
]

# ---- game state
var balls: Array[Ball] = []
var cue: Ball
var pockets := PackedVector2Array()
var state := State.AIMING
var power := 0.5
var player := 0
var groups := [-1, -1]        # -1 open, 0 solids, 1 stripes
var message := ""
var winner := -1
var first_hit := -1
var potted_this_shot: Array[int] = []
var potted_tray: Array[int] = []
var cue_potted := false
var shooter_on_eight := false

# ---- camera
var cam: Camera3D
var aim_yaw := -PI / 2.0
var aim_pitch := deg_to_rad(22.0)
var aim_dist := 1.0
var cam_target := Vector3.ZERO
var cam_yaw := -PI / 2.0
var cam_pitch := deg_to_rad(22.0)
var cam_dist := 1.0

# ---- visuals / hud
var aim_root: Node3D
var aim_line: MeshInstance3D
var target_line: MeshInstance3D
var ghost: MeshInstance3D
var stick: MeshInstance3D
var invalid_marker: MeshInstance3D
var hud: CanvasLayer
var status_label: Label
var msg_label: Label
var over_label: Label
var power_bar: ProgressBar
var tray: Tray


func _ready() -> void:
	var hx := TW / 2.0
	var hz := TH / 2.0
	pockets = PackedVector2Array([
		Vector2(-hx, -hz), Vector2(0, -hz - 0.015), Vector2(hx, -hz),
		Vector2(-hx, hz), Vector2(0, hz + 0.015), Vector2(hx, hz)])
	build_environment()
	build_table()
	build_aim_nodes()
	build_hud()
	cam = Camera3D.new()
	cam.fov = 55.0
	cam.near = 0.02
	cam.far = 60.0
	add_child(cam)
	cam.make_current()
	new_game()
	cam_target = Vector3(cue.pos.x, R, cue.pos.y)


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

func add_box(size: Vector3, pos: Vector3, m: Material) -> void:
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	mi.position = pos
	add_child(mi)

func build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.05, 0.07)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.72, 0.8)
	env.ambient_light_energy = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60, 30, 0)
	sun.light_energy = 0.3
	add_child(sun)

	var lamp := SpotLight3D.new()
	lamp.position = Vector3(0, 2.2, 0)
	lamp.rotation_degrees = Vector3(-90, 0, 0)
	lamp.spot_range = 5.0
	lamp.spot_angle = 55.0
	lamp.light_energy = 3.0
	lamp.shadow_enabled = true
	add_child(lamp)

	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(14, 14)
	floor_mesh.material = mat(Color(0.12, 0.12, 0.15), 0.9)
	var fl := MeshInstance3D.new()
	fl.mesh = floor_mesh
	fl.position = Vector3(0, -0.94, 0)
	add_child(fl)

func build_table() -> void:
	var felt := mat(Color(0.05, 0.42, 0.22), 0.95)
	var cush := mat(Color(0.04, 0.33, 0.17), 0.9)
	var wood := mat(Color(0.33, 0.17, 0.07), 0.4)
	var cw := 0.06   # cushion width
	var rw := 0.14   # wooden rail width
	var cg := 0.07   # gap at corner pockets
	var sg := 0.06   # half gap at side pockets
	var hx := TW / 2.0
	var hz := TH / 2.0

	add_box(Vector3(TW, 0.04, TH), Vector3(0, -0.02, 0), felt)
	add_box(Vector3(TW + 2.0 * (cw + rw), 0.1, TH + 2.0 * (cw + rw)), Vector3(0, -0.09, 0), wood)

	var signs: Array[float] = [-1.0, 1.0]
	var seg_len := hx - cg - sg
	var seg_mid := (sg + hx - cg) / 2.0
	for sz in signs:
		for sx in signs:
			add_box(Vector3(seg_len, 0.08, cw), Vector3(sx * seg_mid, 0.0, sz * (hz + cw / 2.0)), cush)
			add_box(Vector3(seg_len, 0.09, rw), Vector3(sx * seg_mid, 0.005, sz * (hz + cw + rw / 2.0)), wood)
	for sx in signs:
		add_box(Vector3(cw, 0.08, TH - 2.0 * cg), Vector3(sx * (hx + cw / 2.0), 0.0, 0.0), cush)
		add_box(Vector3(rw, 0.09, TH - 2.0 * cg), Vector3(sx * (hx + cw + rw / 2.0), 0.005, 0.0), wood)
		for sz in signs:
			add_box(Vector3(0.14, 0.8, 0.14), Vector3(sx * (hx + cw + rw - 0.1), -0.54, sz * (hz + cw + rw - 0.1)), wood)

	var hole := CylinderMesh.new()
	hole.top_radius = POCKET_R
	hole.bottom_radius = POCKET_R
	hole.height = 0.004
	hole.material = mat(Color(0.01, 0.01, 0.01), 1.0)
	for pk in pockets:
		var mi := MeshInstance3D.new()
		mi.mesh = hole
		mi.position = Vector3(pk.x, 0.002, pk.y)
		add_child(mi)

func make_line() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.material = unshaded(Color.WHITE)
	mi.mesh = bm
	aim_root.add_child(mi)
	return mi

func build_aim_nodes() -> void:
	aim_root = Node3D.new()
	add_child(aim_root)
	aim_line = make_line()
	(aim_line.mesh as BoxMesh).material = unshaded(Color(1, 1, 1, 0.55))
	target_line = make_line()
	(target_line.mesh as BoxMesh).material = unshaded(Color(1, 0.9, 0.3, 0.85))

	var gm := SphereMesh.new()
	gm.radius = R
	gm.height = 2.0 * R
	gm.material = unshaded(Color(1, 1, 1, 0.3))
	ghost = MeshInstance3D.new()
	ghost.mesh = gm
	aim_root.add_child(ghost)

	var cm := CylinderMesh.new()
	cm.top_radius = 0.014
	cm.bottom_radius = 0.006
	cm.height = 1.4
	cm.material = mat(Color(0.8, 0.6, 0.32), 0.4)
	stick = MeshInstance3D.new()
	stick.mesh = cm
	aim_root.add_child(stick)

	var im := CylinderMesh.new()
	im.top_radius = R * 1.5
	im.bottom_radius = R * 1.5
	im.height = 0.002
	im.material = unshaded(Color(1, 0.15, 0.15, 0.6))
	invalid_marker = MeshInstance3D.new()
	invalid_marker.mesh = im
	invalid_marker.visible = false
	add_child(invalid_marker)

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
	pl.text = "Power"
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
	tray.position = Vector2(24, 652)
	tray.colors = ball_colors
	tray.nums = potted_tray
	hud.add_child(tray)
	var hint := make_label(13, Vector2(24, 692))
	hint.text = "Right-drag / Left,Right: aim (Shift = fine)   Wheel: zoom   Up/Down: power   Click / Space: shoot   R: restart"
	hint.modulate = Color(1, 1, 1, 0.65)


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
		var col: Color = ball_colors[num if num <= 8 else num - 8]
		if num <= 8:
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

func make_ball(num: int, p: Vector2) -> Ball:
	var b := Ball.new(num, p)
	var sm := SphereMesh.new()
	sm.radius = R
	sm.height = 2.0 * R
	sm.radial_segments = 48
	sm.rings = 24
	var m := StandardMaterial3D.new()
	m.albedo_texture = make_ball_texture(num)
	m.roughness = 0.15
	m.metallic_specular = 0.8
	sm.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = sm
	mi.position = Vector3(p.x, R, p.y)
	mi.basis = Basis.from_euler(Vector3(randf() * TAU, randf() * TAU, randf() * TAU))
	add_child(mi)
	b.node = mi
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
	power = 0.5
	aim_yaw = -PI / 2.0
	cue = make_ball(0, Vector2(-TW * 0.25, 0.0))
	balls.append(cue)

	var nums: Array = [1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15]
	nums.shuffle()
	nums.insert(4, 8)  # 8-ball in the middle of the rack
	var foot := Vector2(TW * 0.25, 0.0)
	var i := 0
	for col in 5:
		for row in col + 1:
			var p := foot + Vector2(col * (R * 2.0 * 0.8660254 + 0.0004), (row - col / 2.0) * (R * 2.0 + 0.0004))
			balls.append(make_ball(nums[i], p))
			i += 1
	state = State.AIMING
	message = "Player 1 breaks. Aim, set power, then click to shoot."


# ================================================================ helpers
func group_of(n: int) -> int:
	if n == 0: return -1
	if n == 8: return 2
	return 0 if n < 8 else 1

func remaining(g: int) -> int:
	var c := 0
	for b in balls:
		if not b.potted and b.num != 0 and group_of(b.num) == g:
			c += 1
	return c

func any_moving() -> bool:
	for b in balls:
		if not b.potted and b.vel != Vector2.ZERO:
			return true
	return false

func placement_valid(p: Vector2) -> bool:
	if not TABLE.grow(-R).has_point(p): return false
	for pk in pockets:
		if p.distance_to(pk) < POCKET_R + R: return false
	for b in balls:
		if b != cue and not b.potted and b.pos.distance_to(p) < 2.0 * R + 0.002:
			return false
	return true

func aim_dir() -> Vector2:
	return Vector2(-sin(aim_yaw), -cos(aim_yaw))

func to3(p: Vector2) -> Vector3:
	return Vector3(p.x, R, p.y)


# ================================================================ input
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo:
			match k.keycode:
				KEY_R: new_game()
				KEY_SPACE, KEY_ENTER: primary_action()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			match mb.button_index:
				MOUSE_BUTTON_LEFT: primary_action()
				MOUSE_BUTTON_WHEEL_UP: aim_dist = clampf(aim_dist * 0.92, 0.4, 3.0)
				MOUSE_BUTTON_WHEEL_DOWN: aim_dist = clampf(aim_dist / 0.92, 0.4, 3.0)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if state == State.AIMING and (mm.button_mask & MOUSE_BUTTON_MASK_RIGHT) != 0:
			var s := 0.2 if Input.is_key_pressed(KEY_SHIFT) else 1.0
			aim_yaw -= mm.relative.x * 0.003 * s
			aim_pitch = clampf(aim_pitch + mm.relative.y * 0.003, deg_to_rad(8.0), deg_to_rad(85.0))

func primary_action() -> void:
	match state:
		State.AIMING: shoot()
		State.PLACING:
			if placement_valid(cue.pos):
				state = State.AIMING
				message = "Player %d: aim and shoot." % (player + 1)

func shoot() -> void:
	cue.vel = aim_dir() * power * MAX_SPEED
	first_hit = -1
	potted_this_shot.clear()
	cue_potted = false
	shooter_on_eight = groups[player] != -1 and remaining(groups[player]) == 0
	state = State.MOVING
	message = ""


# ================================================================ physics
func _physics_process(delta: float) -> void:
	if state != State.MOVING: return
	var dt := delta / SUBSTEPS
	for s in SUBSTEPS:
		step(dt)
	if not any_moving():
		end_shot()

func step(dt: float) -> void:
	var minp := TABLE.position + Vector2(R, R)
	var maxp := TABLE.end - Vector2(R, R)
	for b in balls:
		if b.potted: continue
		b.pos += b.vel * dt
		var sp := b.vel.length()
		if sp > 0.0:
			var ns := maxf(0.0, sp - FRICTION * dt) * (1.0 - DAMPING * dt)
			b.vel = Vector2.ZERO if ns < STOP_SPEED else b.vel / sp * ns
		for pk in pockets:
			if b.pos.distance_to(pk) < POCKET_R:
				pot(b, pk)
				break
		if b.potted: continue
		if b.pos.x < minp.x:
			b.pos.x = minp.x
			b.vel.x = absf(b.vel.x) * CUSHION_BOUNCE
		elif b.pos.x > maxp.x:
			b.pos.x = maxp.x
			b.vel.x = -absf(b.vel.x) * CUSHION_BOUNCE
		if b.pos.y < minp.y:
			b.pos.y = minp.y
			b.vel.y = absf(b.vel.y) * CUSHION_BOUNCE
		elif b.pos.y > maxp.y:
			b.pos.y = maxp.y
			b.vel.y = -absf(b.vel.y) * CUSHION_BOUNCE
	for i in balls.size():
		var a := balls[i]
		if a.potted: continue
		for j in range(i + 1, balls.size()):
			var c := balls[j]
			if c.potted: continue
			var d := c.pos - a.pos
			var dist := d.length()
			if dist < 2.0 * R and dist > 0.00001:
				var n := d / dist
				var overlap := 2.0 * R - dist
				a.pos -= n * overlap * 0.5
				c.pos += n * overlap * 0.5
				var rel := (a.vel - c.vel).dot(n)
				if rel > 0.0:
					var imp := rel * (1.0 + BALL_BOUNCE) * 0.5
					a.vel -= n * imp
					c.vel += n * imp
					if first_hit < 0 and (a == cue or c == cue):
						first_hit = c.num if a == cue else a.num

func pot(b: Ball, pk: Vector2) -> void:
	b.potted = true
	b.vel = Vector2.ZERO
	if b == cue:
		cue_potted = true
	else:
		potted_this_shot.append(b.num)
		potted_tray.append(b.num)
	if b.tween:
		b.tween.kill()
	b.tween = create_tween()
	b.tween.tween_property(b.node, "position", Vector3(pk.x, -0.1, pk.y), 0.3)
	b.tween.tween_callback(b.node.hide)


# ================================================================ rules
func end_shot() -> void:
	var cur := player
	var other := 1 - player
	var foul := false
	var reason := ""

	if cue_potted:
		foul = true
		reason = "scratch"
	elif first_hit < 0:
		foul = true
		reason = "no ball hit"
	elif shooter_on_eight:
		if first_hit != 8:
			foul = true
			reason = "must hit the 8-ball first"
	elif groups[cur] != -1:
		if group_of(first_hit) != groups[cur]:
			foul = true
			reason = "wrong ball hit first"
	elif first_hit == 8:
		foul = true
		reason = "hit the 8-ball first"

	if potted_this_shot.has(8):
		winner = cur if (shooter_on_eight and not foul) else other
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
		if cue.potted:
			cue.potted = false
			if cue.tween:
				cue.tween.kill()
			cue.node.show()
		cue.vel = Vector2.ZERO
		message = "Foul (%s). Player %d has ball in hand: move the cue ball and click to place it." % [reason, player + 1]
	elif potted_own:
		state = State.AIMING
		message = "Nice shot! Player %d shoots again." % (player + 1)
	else:
		player = other
		state = State.AIMING
		message = "Player %d's turn." % (player + 1)


# ================================================================ per-frame
func _process(delta: float) -> void:
	if state == State.AIMING:
		var slow := 0.25 if Input.is_key_pressed(KEY_SHIFT) else 1.0
		if Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A):
			aim_yaw += delta * slow
		if Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D):
			aim_yaw -= delta * slow
		if Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_W):
			power = clampf(power + 0.5 * delta, 0.05, 1.0)
		if Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_S):
			power = clampf(power - 0.5 * delta, 0.05, 1.0)

	if state == State.PLACING:
		var mp := get_viewport().get_mouse_position()
		var o := cam.project_ray_origin(mp)
		var n := cam.project_ray_normal(mp)
		if n.y < -0.001:
			var hit := o + n * ((R - o.y) / n.y)
			var inner := TABLE.grow(-R)
			cue.pos = Vector2(hit.x, hit.z).clamp(inner.position, inner.end)
			cue.last_pos = cue.pos

	sync_balls()
	update_camera(delta)
	update_aim()
	update_hud()

func sync_balls() -> void:
	for b in balls:
		if b.potted: continue
		b.node.position = to3(b.pos)
		var disp := b.pos - b.last_pos
		if disp.length_squared() > 1e-10:
			var axis := Vector3.UP.cross(Vector3(disp.x, 0.0, disp.y)).normalized()
			b.node.basis = (Basis(axis, disp.length() / R) * b.node.basis).orthonormalized()
		b.last_pos = b.pos

func update_camera(delta: float) -> void:
	var d_target := Vector3.ZERO
	var d_dist := 2.6
	var d_pitch := deg_to_rad(52.0)
	var d_yaw := aim_yaw
	match state:
		State.AIMING:
			d_target = to3(cue.pos)
			d_dist = aim_dist
			d_pitch = aim_pitch
		State.PLACING:
			d_dist = 2.4
			d_pitch = deg_to_rad(85.0)
			d_yaw = 0.0
	var k := 1.0 - exp(-8.0 * delta)
	cam_target = cam_target.lerp(d_target, k)
	cam_dist = lerpf(cam_dist, d_dist, k)
	cam_pitch = lerpf(cam_pitch, d_pitch, k)
	cam_yaw = lerp_angle(cam_yaw, d_yaw, k)
	var off := Vector3(sin(cam_yaw) * cos(cam_pitch), sin(cam_pitch), cos(cam_yaw) * cos(cam_pitch)) * cam_dist
	cam.position = cam_target + off
	cam.look_at(cam_target, Vector3.UP)

func place_line(node: MeshInstance3D, a: Vector3, b: Vector3, w: float) -> void:
	var d := b - a
	var l := d.length()
	node.visible = l > 0.002
	if l <= 0.002: return
	(node.mesh as BoxMesh).size = Vector3(w, w, l)
	node.global_transform = Transform3D(Basis.looking_at(d / l, Vector3.UP), (a + b) * 0.5)

func update_aim() -> void:
	aim_root.visible = state == State.AIMING
	invalid_marker.visible = state == State.PLACING and not placement_valid(cue.pos)
	invalid_marker.position = Vector3(cue.pos.x, 0.004, cue.pos.y)
	if state != State.AIMING: return

	var dir := aim_dir()
	var info := aim_trace(cue.pos, dir)
	var t: float = info["t"]
	var hit: Ball = info["ball"]
	var end := cue.pos + dir * t
	place_line(aim_line, to3(cue.pos), to3(end), 0.004)
	ghost.position = to3(end)
	if hit != null:
		var n := (hit.pos - end).normalized()
		place_line(target_line, to3(hit.pos), to3(hit.pos + n * 0.3), 0.004)
	else:
		target_line.visible = false

	# cue stick, pulled back according to power, slightly tilted up
	var tilt := deg_to_rad(4.0)
	var axis := Vector3(-dir.x * cos(tilt), sin(tilt), -dir.y * cos(tilt))
	var pull := 0.03 + power * 0.22
	var tip := to3(cue.pos) - Vector3(dir.x, 0.0, dir.y) * (R + 0.01 + pull)
	stick.global_transform = Transform3D(
		Basis.looking_at(-axis, Vector3.UP) * Basis(Vector3.RIGHT, PI / 2.0),
		tip + axis * 0.7)

func aim_trace(origin: Vector2, dir: Vector2) -> Dictionary:
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
	var inner := TABLE.grow(-R)
	var tr := INF
	if dir.x > 0.0: tr = minf(tr, (inner.end.x - origin.x) / dir.x)
	elif dir.x < 0.0: tr = minf(tr, (inner.position.x - origin.x) / dir.x)
	if dir.y > 0.0: tr = minf(tr, (inner.end.y - origin.y) / dir.y)
	elif dir.y < 0.0: tr = minf(tr, (inner.position.y - origin.y) / dir.y)
	if tr < best:
		best = tr
		hit = null
	return {"t": best, "ball": hit}

func update_hud() -> void:
	var grp := "open table"
	if groups[player] == 0: grp = "solids"
	elif groups[player] == 1: grp = "stripes"
	if groups[player] != -1 and remaining(groups[player]) == 0: grp = "8-ball"
	status_label.text = "Player %d  (%s)" % [player + 1, grp]
	msg_label.text = message
	power_bar.value = power
	over_label.visible = state == State.GAME_OVER
	if state == State.GAME_OVER:
		over_label.text = "Player %d wins!" % (winner + 1)
	tray.queue_redraw()
