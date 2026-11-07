extends Node3D
# The Gorilla Computer in the Stump, built from the "Gorilla tag fan computer" model
# (Models/FanComputer, CC-BY 4.0 -- see CREDITS.md).
#
#   - the old monitor + keyboard are removed from the map and the fan computer is set on the same table,
#   - the screen shows the GORILLA OS menu (a Label3D laid over the CRT glass),
#   - the keyboard is one painted mesh, so every key is an invisible touch zone placed over the painted key.
#     Touch a key with a hand and it types / presses, like the ComputerKeyTrigger script it is based on:
#       * 0.2 s cooldown per key
#       * room codes are at most 6 characters
#       * ENTER joins the room, BACKSPACE deletes a character
#   - F1/F2/F3 are OPTION 1/2/3, the arrow keys are UP/DOWN, F4 = ROOM, F5 = TURN, F6 = RANDOM ROOM.
#   - the two notice boards (message of the day, code of conduct) get a green chalkboard face.

const MODEL_PATH := "res://Models/FanComputer/scene.gltf"
const SAVE_PATH := "user://gorilla_computer.cfg"

const MAX_ROOM_CODE := 6
const MAX_NAME := 12

@export var board_color:Color = Color(0.05, 0.36, 0.17)
@export var screen_color:Color = Color(0.02, 0.05, 0.04)
@export var model_scale:float = 0.8 # the model is ~2 units wide; 0.8 fits the table
@export var key_cooldown:float = 0.2 # seconds before the same key can be pressed again (ComputerKeyTrigger.cooldownTime)
@export var touch_height:float = 0.10 # metres above the keyboard a hand still counts as touching a key
@export var haptic_amplitude:float = 0.5

# Painted key centres, in pixels of the top-view of the keyboard mesh (979 px per model unit).
# id -> [x, y]; ids are what _key() understands.
const KEY_PX_PER_UNIT := 979.0
const KEY_POS := {
	"1": [125, 172], "2": [188, 172], "3": [250, 172], "4": [312, 172], "5": [373, 172],
	"6": [435, 172], "7": [496, 172], "8": [558, 172], "9": [618, 172], "0": [680, 172],
	"q": [126, 231], "w": [188, 231], "e": [250, 231], "r": [312, 231], "t": [372, 231],
	"y": [435, 231], "u": [497, 231], "i": [558, 231], "o": [618, 231], "p": [680, 231],
	"a": [126, 292], "s": [188, 292], "d": [250, 292], "f": [312, 292], "g": [372, 292],
	"h": [435, 292], "j": [497, 292], "k": [558, 292], "l": [618, 292],
	"z": [126, 350], "x": [188, 350], "c": [250, 350], "v": [312, 350], "b": [372, 350],
	"n": [435, 350], "m": [497, 350],
	"delete": [770, 172], "enter": [775, 292],
	"opt1": [130, 75], "opt2": [190, 75], "opt3": [252, 75],
	"rooms": [313, 75], "turn": [375, 75], "random": [433, 75],
	"up": [975, 343], "down": [975, 400],
}
# numpad: [x, y, id]
const NUMPAD := [
	[1152, 228, "7"], [1213, 228, "8"], [1272, 228, "9"],
	[1152, 290, "4"], [1213, 290, "5"], [1272, 290, "6"],
	[1152, 343, "1"], [1213, 343, "2"], [1272, 343, "3"],
	[1182, 403, "0"], [1332, 372, "enter"],
]

# Screen rectangle on the CRT glass, in model units (read off the model's geometry).
const SCREEN_X0 := -0.85
const SCREEN_X1 := 0.543
const SCREEN_Y0 := -0.24
const SCREEN_Y1 := 0.593
const SCREEN_Z := -0.234

var _player_container:Node3D
var _hands:Array = []
var _ctrls:Array = []
var _body:Node
var _screen:Label3D
var _model:Node3D
var _keys_list:Array = [] # {id, pos (world, keyboard surface), next (time), }
var _kb_up := Vector3.UP
var _kb_top := 0.0
var _pitch := 0.05
var _near := [null, null]
var _flash:Array = []
var _flash_left := [0.0, 0.0]
var _click:AudioStreamPlayer3D
var _now := 0.0

# computer state
var _mode := "menu"
var _page := 0
var _name := "GORILLA"
var _room := ""
var _typing := ""
var _channel := 0 # 0 red, 1 green, 2 blue
var _rgb := [5, 5, 5]
var _turn := "SNAP"
var _turn_speed := 5

func setup(map:Node, player_container:Node3D, body:Node) -> void:
	_body = body
	_player_container = player_container
	_hands = [player_container.get_node_or_null("LeftHandFollower"), player_container.get_node_or_null("RightHandFollower")]
	_ctrls = [player_container.get_node_or_null("Player/XROrigin3D/LeftHand"), player_container.get_node_or_null("Player/XROrigin3D/RightHand")]
	_board(map, "motd_fixed", "board")
	_board(map, "code_of_conduct_fixed", "board_1")
	_build_computer(map)
	if _load():
		_apply_color() # only recolour if you have saved a colour before
	_apply_turn()
	_render()

func _surface_named(mi:MeshInstance3D, base:String) -> int:
	if mi == null or mi.mesh == null:
		return -1
	for i in mi.mesh.get_surface_count():
		var m := mi.mesh.surface_get_material(i)
		if m != null and m.resource_name.to_lower().begins_with(base):
			return i
	return -1

func _board(map:Node, holder:String, mesh_name:String) -> void:
	var h := map.find_child(holder, true, false)
	if h == null:
		return
	var mi := h.find_child(mesh_name, true, false) as MeshInstance3D
	var s := _surface_named(mi, "screen")
	if s < 0:
		return
	var m := StandardMaterial3D.new()
	m.albedo_color = board_color
	m.roughness = 0.9
	m.emission_enabled = true
	m.emission = board_color
	m.emission_energy_multiplier = 0.25
	mi.set_surface_override_material(s, m)

# ---------------------------------------------------------------------------------------------
# Building the fan computer on the table
# ---------------------------------------------------------------------------------------------

func _world_aabb(mi:MeshInstance3D) -> AABB:
	return mi.global_transform * mi.get_aabb()

func _mesh_under(root:Node, group:String) -> MeshInstance3D:
	var g := root.find_child(group, true, false)
	if g == null:
		return null
	if g is MeshInstance3D:
		return g
	for c in g.find_children("*", "MeshInstance3D", true, false):
		return c as MeshInstance3D
	return null

func _build_computer(map:Node) -> void:
	var gc := map.find_child("GorillaComputer_fixed", true, false)
	if gc == null:
		push_warning("GorillaComputer: 'GorillaComputer_fixed' not found in the map")
		return
	var table := gc.find_child("table__1_", true, false) as MeshInstance3D
	var scene := load(MODEL_PATH) as PackedScene
	if table == null or scene == null:
		push_warning("GorillaComputer: table or %s missing -- keeping the original computer" % MODEL_PATH)
		return
	# the table the computer sits on, then the old monitor + keyboard go away (look and collision)
	var tb := _world_aabb(table)
	for old in ["monitor", "keyboard"]:
		var n := gc.get_node_or_null(old)
		if n != null:
			n.get_parent().remove_child(n)
			n.queue_free()

	var pivot := Node3D.new()
	pivot.name = "FanComputer"
	add_child(pivot)
	_model = scene.instantiate() as Node3D
	pivot.add_child(_model)

	var kb_mi := _mesh_under(_model, "Key_Board_Low")
	var mon_mi := _mesh_under(_model, "Computer_Low")
	if kb_mi == null or mon_mi == null:
		push_warning("GorillaComputer: keyboard / monitor meshes not found in the model")
		return
	# the model's front is +Z (keyboard on the +Z side of the monitor). If the importer turned it round, turn it back.
	var kb_c := pivot.to_local(_world_aabb(kb_mi).get_center())
	var mon_c := pivot.to_local(_world_aabb(mon_mi).get_center())
	if kb_c.z < mon_c.z:
		_model.rotation.y = PI
	# face the player: the front (+Z of the model) points to -X in the map (the player stands on the stool side)
	pivot.rotation.y = -PI / 2.0
	pivot.scale = Vector3.ONE * model_scale
	# sit it on the table: bottom of the model on the table top, centred on the table
	var mb := AABB()
	var first := true
	for mi in _model.find_children("*", "MeshInstance3D", true, false):
		var wb := _world_aabb(mi as MeshInstance3D)
		mb = wb if first else mb.merge(wb)
		first = false
	pivot.global_position += Vector3(tb.get_center().x - mb.get_center().x, (tb.position.y + tb.size.y) - mb.position.y, tb.get_center().z - mb.get_center().z)

	_add_collision(_model)
	_screen_setup(mon_mi)
	_keys(kb_mi)
	_make_click()

func _add_collision(root:Node) -> void:
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		var shape := m.mesh.create_trimesh_shape()
		if shape == null:
			continue
		var body := StaticBody3D.new()
		body.name = "Collision"
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		m.add_child(body)

# A dark pane laid over the CRT glass plus the menu text.
func _screen_setup(mon_mi:MeshInstance3D) -> void:
	var holder := Node3D.new()
	holder.name = "Screen"
	mon_mi.get_parent().add_child(holder)
	holder.global_transform = mon_mi.global_transform
	# the monitor mesh sits at the model's origin, so model coordinates == the mesh's local coordinates
	var pane := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(SCREEN_X1 - SCREEN_X0, SCREEN_Y1 - SCREEN_Y0)
	pane.mesh = quad
	var m := StandardMaterial3D.new()
	m.albedo_color = screen_color
	m.emission_enabled = true
	m.emission = Color(0.05, 0.25, 0.12)
	m.emission_energy_multiplier = 0.3
	pane.material_override = m
	pane.position = Vector3((SCREEN_X0 + SCREEN_X1) * 0.5, (SCREEN_Y0 + SCREEN_Y1) * 0.5, SCREEN_Z + 0.002)
	holder.add_child(pane)
	var width_px := 520.0
	_screen = Label3D.new()
	_screen.font_size = 26
	_screen.width = width_px
	_screen.autowrap_mode = TextServer.AUTOWRAP_OFF
	_screen.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_screen.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_screen.pixel_size = (SCREEN_X1 - SCREEN_X0) * 0.9 / width_px
	_screen.modulate = Color(0.35, 1.0, 0.5)
	_screen.outline_size = 0
	_screen.shaded = false
	_screen.position = Vector3(SCREEN_X0 + (SCREEN_X1 - SCREEN_X0) * 0.05, SCREEN_Y1 - (SCREEN_Y1 - SCREEN_Y0) * 0.05, SCREEN_Z + 0.004)
	holder.add_child(_screen)

# ---------------------------------------------------------------------------------------------
# Keys: invisible touch zones over the painted keyboard
# ---------------------------------------------------------------------------------------------

func _keys(kb_mi:MeshInstance3D) -> void:
	var ab := kb_mi.get_aabb() # mesh space == model space here
	var x0 := ab.position.x
	var z0 := ab.position.z - 0.004
	var top := ab.position.y + ab.size.y
	var xf := kb_mi.global_transform
	_kb_up = xf.basis.y.normalized()
	_kb_top = (xf * Vector3(0, top, 0)).y
	_pitch = 62.0 / KEY_PX_PER_UNIT * model_scale
	for id in KEY_POS:
		_add_key(id, xf, x0, z0, top, KEY_POS[id][0], KEY_POS[id][1])
	for k in NUMPAD:
		_add_key(k[2], xf, x0, z0, top, k[0], k[1])
	for i in 2:
		var q := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(0.04, 0.04)
		quad.orientation = PlaneMesh.FACE_Y
		q.mesh = quad
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(1.0, 0.1, 0.1, 0.8)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		q.material_override = m
		q.top_level = true
		q.visible = false
		add_child(q)
		_flash.append(q)

func _add_key(id:String, xf:Transform3D, x0:float, z0:float, top:float, px:float, py:float) -> void:
	var local := Vector3(x0 + px / KEY_PX_PER_UNIT, top, z0 + py / KEY_PX_PER_UNIT)
	_keys_list.append({"id": id, "pos": xf * local, "next": 0.0})

func _make_click() -> void:
	var n := 700
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		data.encode_s16(i * 2, int(randf_range(-1.0, 1.0) * 14000.0 * exp(-float(i) / 120.0)))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 22050
	wav.data = data
	_click = AudioStreamPlayer3D.new()
	_click.stream = wav
	_click.unit_size = 2.0
	_click.max_distance = 15.0
	add_child(_click)

# ---------------------------------------------------------------------------------------------
# Typing: touch a key with a hand
# ---------------------------------------------------------------------------------------------

func _process(delta:float) -> void:
	_now += delta
	for h in 2:
		if _flash_left[h] > 0.0:
			_flash_left[h] -= delta
			if _flash_left[h] <= 0.0 and h < _flash.size():
				(_flash[h] as Node3D).visible = false
	if _keys_list.is_empty():
		return
	for h in _hands.size():
		var hand := _hands[h] as Node3D
		if hand == null:
			continue
		var hp := hand.global_position
		var best = null
		var bd := _pitch * 0.55
		if hp.y - _kb_top < touch_height and hp.y - _kb_top > -0.08:
			for k in _keys_list:
				var kp:Vector3 = k.pos
				var d := Vector2(hp.x - kp.x, hp.z - kp.z).length()
				if d < bd:
					bd = d
					best = k
		# the Unity trigger fires when a hand ENTERS a key: press once on entering, per-key cooldown
		if best != null and best != _near[h] and _now >= best.next:
			best.next = _now + key_cooldown
			_press(best, h)
		_near[h] = best

func _press(k:Dictionary, hand:int) -> void:
	if hand < _flash.size():
		var q := _flash[hand] as Node3D
		q.global_position = (k.pos as Vector3) + Vector3(0, 0.003, 0)
		q.global_rotation = Vector3(0, global_rotation.y, 0)
		q.visible = true
		_flash_left[hand] = 0.15
	var ctrl := _ctrls[hand] as XRController3D
	if ctrl != null:
		ctrl.trigger_haptic_pulse("haptic", 0.0, haptic_amplitude, 0.05, 0.0)
	if _click != null:
		_click.global_position = k.pos
		_click.play()
	_key(k.id)
	_render()

func _key(id:String) -> void:
	# shortcuts
	if id == "rooms":
		_mode = "room"
		_typing = ""
		return
	if id == "turn":
		_mode = "turn"
		return
	if id == "random" and _mode == "menu":
		_mode = "message"
		_typing = "JOINING RANDOM ROOM...\n\nOFFLINE: NO NETWORK IN THIS BUILD"
		return
	match _mode:
		"message":
			_mode = "menu"
		"menu":
			if id == "opt1" and _page == 0: _mode = "room"; _typing = ""
			elif id == "opt2" and _page == 0: _mode = "name"; _typing = _name
			elif id == "opt3" and _page == 0: _mode = "color"
			elif id == "opt1" and _page == 1: _mode = "turn"
			elif id == "down": _page = mini(_page + 1, 1)
			elif id == "up": _page = maxi(_page - 1, 0)
		"name", "room":
			if id == "enter":
				if _mode == "name" and _typing != "":
					_name = _typing
					_save()
				elif _mode == "room":
					# ComputerKeyTrigger: ENTER hands the typed code to the network join call (none in this build)
					if _typing != "":
						_room = _typing
						_mode = "message"
						_typing = "JOINING ROOM %s...\n\nOFFLINE: NO NETWORK IN THIS BUILD" % _room
						return
				_mode = "menu"
			elif id == "delete":
				_typing = _typing.substr(0, maxi(0, _typing.length() - 1))
			elif id.length() == 1 and _typing.length() < (MAX_ROOM_CODE if _mode == "room" else MAX_NAME):
				_typing += id.to_upper()
		"color":
			if id == "opt1": _channel = 0
			elif id == "opt2": _channel = 1
			elif id == "opt3": _channel = 2
			elif id.length() == 1 and id >= "0" and id <= "9":
				_rgb[_channel] = int(id)
				_apply_color()
			elif id == "enter": _mode = "menu"
		"turn":
			if id == "opt1": _turn = "SNAP"
			elif id == "opt2": _turn = "SMOOTH"
			elif id == "opt3": _turn = "NONE"
			elif id == "up": _turn_speed = mini(_turn_speed + 1, 9)
			elif id == "down": _turn_speed = maxi(_turn_speed - 1, 1)
			elif id == "enter": _mode = "menu"
			_apply_turn()
			_save()

func _load() -> bool:
	var cf := ConfigFile.new()
	if cf.load(SAVE_PATH) != OK:
		return false
	_name = str(cf.get_value("computer", "name", _name))
	_rgb = [clampi(int(cf.get_value("computer", "r", _rgb[0])), 0, 9), clampi(int(cf.get_value("computer", "g", _rgb[1])), 0, 9), clampi(int(cf.get_value("computer", "b", _rgb[2])), 0, 9)]
	_turn = str(cf.get_value("computer", "turn", _turn))
	_turn_speed = clampi(int(cf.get_value("computer", "turn_speed", _turn_speed)), 1, 9)
	return true

func _save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("computer", "name", _name)
	cf.set_value("computer", "r", _rgb[0])
	cf.set_value("computer", "g", _rgb[1])
	cf.set_value("computer", "b", _rgb[2])
	cf.set_value("computer", "turn", _turn)
	cf.set_value("computer", "turn_speed", _turn_speed)
	cf.save(SAVE_PATH)

func _apply_turn() -> void:
	if _player_container != null and _player_container.has_method("set_turn"):
		_player_container.set_turn(_turn, _turn_speed)

func _apply_color() -> void:
	if _body != null and _body.has_method("set_gorilla_color"):
		_body.set_gorilla_color(Color(_rgb[0] / 9.0, _rgb[1] / 9.0, _rgb[2] / 9.0))
		_save()

func _render() -> void:
	if _screen == null:
		return
	var t := ""
	match _mode:
		"menu":
			t = "GORILLA OS\n\nROOM: %s\nNAME: %s\n\n" % [_room if _room != "" else "-NOT CONNECTED-", _name]
			if _page == 0:
				t += "F1: ROOM\nF2: NAME\nF3: COLOR\n\nDOWN ARROW: MORE"
			else:
				t += "F1: TURN\n\nUP ARROW: BACK"
		"name":
			t = "ENTER YOUR NAME:\n\n> %s_\n\nENTER: SAVE\nBACKSPACE: ERASE" % _typing
		"room":
			t = "ENTER ROOM CODE (MAX 6):\n\n> %s_\n\nENTER: JOIN (OFFLINE)\nBACKSPACE: ERASE" % _typing
		"color":
			t = "COLOR\n\n%sRED:   %d\n%sGREEN: %d\n%sBLUE:  %d\n\nF1-F3: PICK\nTYPE 0-9: SET\nENTER: BACK" % [
				">" if _channel == 0 else " ", _rgb[0], ">" if _channel == 1 else " ", _rgb[1], ">" if _channel == 2 else " ", _rgb[2]]
		"turn":
			t = "TURN\n\nF1: SNAP\nF2: SMOOTH\nF3: NONE\n\nMODE: %s  SPEED: %d\nUP/DOWN ARROW: SPEED\nENTER: BACK" % [_turn, _turn_speed]
		"message":
			t = _typing + "\n\nPRESS ANY KEY"
	_screen.text = t
