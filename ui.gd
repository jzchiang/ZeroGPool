extends Node
class_name GameUI

signal spin_changed(v: Vector2)
signal play_requested
signal resume_requested
signal quit_requested

const HELP_TEXT := """GOAL
Pot all the balls of your group, then the black ball (35). Solids are 1-17, stripes are 18-34. The first ball you pot sets your group. There are 12 pockets: the 8 corners and the middles of the 4 long edges.

SHOOTING
Hold the left mouse button and drag DOWN to pull the cue back, release to shoot (Esc cancels).
Right-drag or A / D / W / S to aim (hold Shift for fine aim).
T aims at the nearest ball, press again for the next one.
Arrow keys or the ball pad choose where the cue tip hits the ball (spin). Spin curves the shot, and C re-centers it.

CAMERA (a free trackball: there is no fixed "up")
Ctrl + right-drag or middle-drag to orbit over any pole, Q / E to roll, mouse wheel to zoom.
Keys 1-6, or a click on the orientation cube, snap to the +X, -X, +Y, -Y, +Z and -Z views. The box edges are colored by axis: X red, Y green, Z blue.
F looks along the aim line, L levels the horizon.

FOULS
A scratch, hitting no ball, or hitting the wrong group first gives your opponent ball in hand: move the mouse, use the wheel to change depth, click to place.

M or Esc opens this menu, R restarts the game."""

class Tray extends Control:
	var nums: Array[int] = []
	var colors: Array[Color] = []
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
var hud_layer: CanvasLayer
var menu_layer: CanvasLayer
var status_label: Label
var msg_label: Label
var over_label: Label
var power_bar: ProgressBar
var tray: Tray
var spin_pad: SpinPad
var spin_label: Label
var menu_box: VBoxContainer
var help_box: VBoxContainer
var resume_btn: Button

var help_visible: bool:
	get:
		return help_box.visible

func _ready() -> void:
	_build_hud()
	_build_menu()

func make_label(text_size: int, pos: Vector2, width := 0.0) -> Label:
	var label := Label.new()
	label.position = pos
	label.add_theme_font_size_override("font_size", text_size)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 6)
	if width > 0.0:
		label.custom_minimum_size = Vector2(width, 0)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hud_layer.add_child(label)
	return label

func _build_hud() -> void:
	hud_layer = CanvasLayer.new()
	add_child(hud_layer)
	status_label = make_label(26, Vector2(24, 14))
	msg_label = make_label(16, Vector2(24, 52), 900.0)
	msg_label.add_theme_color_override("font_color", Color(1, 0.95, 0.6))
	var power_label := make_label(14, Vector2(1000, 8))
	power_label.text = "Power (hold LMB, drag down)"
	power_bar = ProgressBar.new()
	power_bar.position = Vector2(1000, 32)
	power_bar.custom_minimum_size = Vector2(250, 20)
	power_bar.min_value = 0.0
	power_bar.max_value = 1.0
	power_bar.show_percentage = false
	hud_layer.add_child(power_bar)
	over_label = make_label(56, Vector2(0, 280), 1280.0)
	over_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	over_label.visible = false
	tray = Tray.new()
	tray.position = Vector2(24, 622)
	tray.colors = ball_colors
	hud_layer.add_child(tray)
	spin_label = make_label(14, Vector2(1112, 528))
	spin_label.text = "Cue tip (C = center)"
	spin_pad = SpinPad.new()
	spin_pad.position = Vector2(1140, 556)
	spin_pad.custom_minimum_size = Vector2(112, 112)
	spin_pad.size = Vector2(112, 112)
	spin_pad.changed.connect(func(v: Vector2) -> void: spin_changed.emit(v))
	hud_layer.add_child(spin_pad)
	var hint := make_label(13, Vector2(24, 662), 1080.0)
	hint.text = "LMB hold + drag down: power, release to shoot (Esc cancels)   Right-drag / A,D,W,S: aim   Ctrl+Right-drag / MMB: orbit   Q/E: roll   1-6: axis views   L: level   F: behind aim   T: next target   Wheel: zoom   Arrows / pad: spin   R: restart"
	hint.modulate = Color(1, 1, 1, 0.65)

func update_hud(status: String, message: String, power: float, game_over_text: String,
		is_aiming: bool, spin_offset: Vector2, potted_nums: Array[int], is_visible: bool) -> void:
	hud_layer.visible = is_visible
	status_label.text = status
	msg_label.text = message
	power_bar.value = power
	over_label.visible = not game_over_text.is_empty()
	if not game_over_text.is_empty():
		over_label.text = game_over_text
	spin_pad.visible = is_aiming
	spin_label.visible = is_aiming
	spin_pad.offset = spin_offset
	spin_pad.queue_redraw()
	tray.nums = potted_nums
	tray.queue_redraw()

func _menu_label(text: String, size: int, color: Color, parent: Control) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 10)
	parent.add_child(label)
	return label

func _menu_button(text: String, parent: Control, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(320, 54)
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 24)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _build_menu() -> void:
	menu_layer = CanvasLayer.new()
	menu_layer.layer = 10
	add_child(menu_layer)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.07, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu_layer.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu_layer.add_child(center)
	menu_box = VBoxContainer.new()
	menu_box.add_theme_constant_override("separation", 14)
	center.add_child(menu_box)
	_menu_label("ZERO-G POOL", 84, Color(0.75, 0.92, 1.0), menu_box)
	_menu_label("36 balls  -  12 pockets  -  no gravity", 20, Color(1, 0.95, 0.65), menu_box)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 28)
	menu_box.add_child(gap)
	_menu_button("Play", menu_box, func() -> void: play_requested.emit())
	resume_btn = _menu_button("Resume game", menu_box, func() -> void: resume_requested.emit())
	resume_btn.visible = false
	_menu_button("How to play", menu_box, show_help)
	_menu_button("Quit", menu_box, func() -> void: quit_requested.emit())
	help_box = VBoxContainer.new()
	help_box.add_theme_constant_override("separation", 16)
	help_box.visible = false
	center.add_child(help_box)
	_menu_label("HOW TO PLAY", 48, Color(0.75, 0.92, 1.0), help_box)
	var panel := PanelContainer.new()
	help_box.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 22)
	panel.add_child(margin)
	var text := Label.new()
	text.text = HELP_TEXT
	text.custom_minimum_size = Vector2(860, 0)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_theme_font_size_override("font_size", 17)
	margin.add_child(text)
	_menu_button("Back", help_box, show_menu_options)

func open_menu(can_resume: bool) -> void:
	resume_btn.visible = can_resume
	menu_box.visible = true
	help_box.visible = false
	menu_layer.visible = true

func hide_menu() -> void:
	menu_layer.visible = false

func show_help() -> void:
	menu_box.visible = false
	help_box.visible = true

func show_menu_options() -> void:
	help_box.visible = false
	menu_box.visible = true
