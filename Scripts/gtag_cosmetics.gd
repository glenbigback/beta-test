extends Node
# Gorilla Tag hat room (stump, upper level).
#
# - Touch a button with a hand and you put that cosmetic on, touch it again and it comes off. Like
#   in the real game you wear at most one HAT, one FACE item and one BADGE at a time, so picking a
#   new hat swaps your old one.
# - The button turns green while its cosmetic is worn, gets a label, squashes when touched and buzzes
#   the controller. Buttons are touch triggers, not solid blocks (see gtag_map.gd).
# - Worn items are copies of the ones on the shelf heads. Each is placed on your gorilla's head with
#   exactly the offset it has on the shelf head model, so they sit like they do in Gorilla Tag.
# - Like in Gorilla Tag you do not see your own hat/glasses from the inside, only in the mirror (and
#   on other players). Set show_in_first_person to see them on yourself anyway.
# - What you wear is remembered between sessions.

const BODY_LAYER := 1 << 10 # your own body (what your headset sees)
const MIRROR_LAYER := 1 << 11 # the mirror copy of your body (what mirrors see)
const SAVE_PATH := "user://gtag_cosmetics.cfg"

# button node name -> [label on the button, shelf head model that shows the item, slot]
const ITEMS := {
	"Cowboy_Hat_Button": ["COWBOY\nHAT", "cowboyhatmodel", "hat"],
	"Fez_Button": ["FEZ", "fezmodel", "hat"],
	"Sunglasses_Button": ["SUNGLASSES", "sunglasses_model", "face"],
	"Top_Hat_Button": ["TOP\nHAT", "tophatmodel", "hat"],
	"Coconut_Button": ["COCONUT", "coconut_model", "hat"],
	"Early_Access_Badge": ["EARLY\nACCESS", "early_access_model", "badge"],
	"Cloche_Button": ["CLOCHE", "cloche_model", "hat"],
	"SunglassesF_Badge": ["SUNGLASSES\nF", "sunglassesf", "face"],
	"Sunhat_Button": ["SUN\nHAT", "sunhat_model", "hat"],
	"Bananahat_Button": ["BANANA\nHAT", "bananahat_model", "hat"],
}
const BANANA_KEY := "Bananahat_Button"

@export var color_idle:Color = Color(0.72, 0.12, 0.12) # button colour when the item is off
@export var color_worn:Color = Color(0.15, 0.68, 0.22) # button colour when the item is worn
@export var press_reach:float = 0.045 # metres around the button a hand must be within to press it
@export var press_cooldown:float = 0.35 # seconds before the same button can be pressed again
@export var show_in_first_person:bool = false # draw your own cosmetics on your real body too

# shelf head model (Z up, face towards -Y, shelf units) -> the player's gorilla head (model units).
# Scale 0.008 and the offsets line the shelf head's width, front and crown up with the player's head.
var head_to_player := Transform3D(
	Basis(Vector3(0.008, 0.0, 0.0), Vector3(0.0, 0.0, -0.008), Vector3(0.0, 0.008, 0.0)),
	Vector3(0.0, 0.297, 0.0364))

class Item:
	var key := ""
	var label := ""
	var slot := ""
	var button:MeshInstance3D
	var material:StandardMaterial3D
	var base_scale := Vector3.ONE
	var center := Vector3.ZERO # button mesh centre (button local space)
	var half := Vector3.ONE # button mesh half size (button local space)
	var reach := 0.0 # press_reach converted to button local units
	var worn := false
	var inside := [false, false] # per hand: is it currently touching?
	var cooldown := 0.0
	var worn_nodes:Array[Node3D] = [] # [on your real body, on the mirror body]

var _items:Array[Item] = []
var _hands:Array[Node3D] = []
var _ctrls:Array = []
var _rigs:Array = []
var _room_center := Vector3.ZERO
var _has_room := false

func setup(map:Node, body:Node, _player_container:Node) -> void:
	var root := map.find_child("Cosmetics", true, false)
	if root == null:
		push_warning("GTagCosmetics: 'Cosmetics' node not found in the map")
		return
	if body != null:
		_hands.clear()
		_hands.append(body.get("left_target") as Node3D)
		_hands.append(body.get("right_target") as Node3D)
		_ctrls = [body.get("left_ctrl"), body.get("right_ctrl")]
		var rigs = body.get("head_rigs")
		if rigs != null:
			_rigs = rigs

	var sum := Vector3.ZERO
	for key in ITEMS:
		var def:Array = ITEMS[key]
		var btn := root.get_node_or_null(String(key)) as MeshInstance3D
		if btn == null or btn.mesh == null:
			push_warning("GTagCosmetics: button '%s' not found" % key)
			continue
		var item := Item.new()
		item.key = String(key)
		item.label = def[0]
		item.slot = def[2]
		item.button = btn
		item.base_scale = btn.scale
		var box := btn.mesh.get_aabb()
		item.center = box.get_center()
		item.half = box.size * 0.5
		item.reach = press_reach / maxf(btn.global_basis.get_scale().x, 0.00001)

		# its own material so only this button changes colour
		item.material = StandardMaterial3D.new()
		item.material.roughness = 0.55
		for s in btn.mesh.get_surface_count():
			btn.set_surface_override_material(s, item.material)
		_add_label(item)

		# worn copies on the real body and on the mirror body
		var head := map.find_child(String(def[1]), true, false) as Node3D
		if head != null and _rigs.size() >= 2:
			for r in 2:
				var holder := _make_holder(item, head)
				_set_layers(holder, BODY_LAYER if r == 0 else MIRROR_LAYER)
				holder.visible = false
				(_rigs[r] as Node3D).add_child(holder)
				item.worn_nodes.append(holder)
		elif head == null:
			push_warning("GTagCosmetics: shelf model '%s' not found" % def[1])

		sum += btn.global_position
		_items.append(item)
		_apply_visual(item)

	if not _items.is_empty():
		_room_center = sum / float(_items.size())
		_has_room = true
	_load()

func get_room_center() -> Vector3:
	return _room_center

func has_room_center() -> bool:
	return _has_room

func _add_label(item:Item) -> void:
	var lbl := Label3D.new()
	lbl.name = "Label"
	lbl.text = item.label
	lbl.font_size = 48
	lbl.pixel_size = 0.22 # button local units per pixel
	lbl.outline_size = 10
	lbl.outline_modulate = Color(0, 0, 0, 1)
	lbl.shaded = false
	lbl.double_sided = false
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# the readable face of the button is its -Z side
	lbl.position = item.center + Vector3(0.0, 0.0, -(item.half.z + 0.6))
	lbl.rotation = Vector3(0.0, PI, 0.0)
	item.button.add_child(lbl)

# Builds one worn copy of an item, positioned for the player's head.
func _make_holder(item:Item, head:Node3D) -> Node3D:
	var holder := Node3D.new()
	holder.name = "Worn_" + item.key
	if item.key == BANANA_KEY:
		# the shelf has no banana mesh (the FBX lost it), so it is built from code
		holder.transform = head_to_player
		holder.add_child(_make_banana())
		return holder

	# shelf head transform without its stray shear, so the item keeps its exact shelf offset
	var ref := head.global_transform
	var sc := ref.basis.get_scale().abs()
	var avg := maxf((sc.x + sc.y + sc.z) / 3.0, 0.00001)
	var inv := Transform3D(ref.basis.orthonormalized() * avg, ref.origin).affine_inverse()
	for c in head.get_children():
		if not (c is Node3D):
			continue
		var src := c as Node3D
		var copy := src.duplicate() as Node3D
		_strip_collision(copy)
		copy.transform = Transform3D.IDENTITY
		var wrap := Node3D.new()
		wrap.transform = head_to_player * (inv * src.global_transform)
		wrap.add_child(copy)
		holder.add_child(wrap)
	return holder

func _strip_collision(n:Node) -> void:
	for child in n.get_children():
		if child is StaticBody3D or child is CollisionShape3D:
			n.remove_child(child)
			child.free()
		else:
			_strip_collision(child)

func _set_layers(n:Node, layers:int) -> void:
	if n is GeometryInstance3D:
		var g := n as GeometryInstance3D
		g.layers = layers
		g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in n.get_children():
		_set_layers(c, layers)

# ---------------------------------------------------------------------------------------------
# touching buttons

func _process(delta:float) -> void:
	for item in _items:
		item.cooldown = maxf(item.cooldown - delta, 0.0)
		for h in _hands.size():
			var hand := _hands[h] as Node3D
			if hand == null:
				continue
			var inside := _touching(item, hand.global_position)
			if inside and not item.inside[h] and item.cooldown <= 0.0:
				item.cooldown = press_cooldown
				_press(item, h)
			item.inside[h] = inside

func _touching(item:Item, world_pos:Vector3) -> bool:
	if not is_instance_valid(item.button) or not item.button.is_inside_tree():
		return false
	var p := item.button.global_transform.affine_inverse() * world_pos - item.center
	var lim := item.half + Vector3.ONE * item.reach
	return absf(p.x) <= lim.x and absf(p.y) <= lim.y and absf(p.z) <= lim.z

func _press(item:Item, hand_index:int) -> void:
	if item.worn:
		_set_worn(item, false)
	else:
		for other in _items: # one hat, one face item, one badge
			if other != item and other.slot == item.slot and other.worn:
				_set_worn(other, false)
		_set_worn(item, true)
	_save()
	_haptic(hand_index)
	_squash(item)

func _haptic(hand_index:int) -> void:
	if hand_index < _ctrls.size():
		var ctrl = _ctrls[hand_index]
		if ctrl != null and ctrl.has_method("trigger_haptic_pulse"):
			ctrl.trigger_haptic_pulse("haptic", 0.0, 0.8, 0.12, 0.0)

func _squash(item:Item) -> void:
	if not is_instance_valid(item.button):
		return
	item.button.scale = item.base_scale
	var tw := create_tween()
	tw.tween_property(item.button, "scale", item.base_scale * Vector3(1.0, 1.0, 0.55), 0.05)
	tw.tween_property(item.button, "scale", item.base_scale, 0.12)

func _set_worn(item:Item, worn:bool) -> void:
	item.worn = worn
	_apply_visual(item)

func _apply_visual(item:Item) -> void:
	if item.material != null:
		if item.worn:
			item.material.albedo_color = color_worn
			item.material.emission_enabled = true
			item.material.emission = color_worn
			item.material.emission_energy_multiplier = 0.6
		else:
			item.material.albedo_color = color_idle
			item.material.emission_enabled = false
	for i in item.worn_nodes.size():
		if is_instance_valid(item.worn_nodes[i]):
			item.worn_nodes[i].visible = item.worn and (i == 1 or show_in_first_person)

# ---------------------------------------------------------------------------------------------
# remembering what you wear

func _save() -> void:
	var worn := PackedStringArray()
	for item in _items:
		if item.worn:
			worn.append(item.key)
	var cf := ConfigFile.new()
	cf.set_value("cosmetics", "worn", worn)
	cf.save(SAVE_PATH)

func _load() -> void:
	var cf := ConfigFile.new()
	if cf.load(SAVE_PATH) != OK:
		return
	var worn:PackedStringArray = cf.get_value("cosmetics", "worn", PackedStringArray())
	var taken := {}
	for item in _items:
		if worn.has(item.key) and not taken.has(item.slot):
			taken[item.slot] = true
			_set_worn(item, true)

# ---------------------------------------------------------------------------------------------
# banana hat (built from code, shelf head units: Z up, face towards -Y)
#
# The FBX only has the banana's bones (three chains 120 degrees apart around the crown), the skinned
# mesh itself was not exported. This is a stand-in: a banana standing on the crown with three peel
# flaps hanging down along the same three directions the bones point.

func _make_banana() -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var yellow := Color(0.96, 0.80, 0.12)
	var brown := Color(0.30, 0.19, 0.07)

	# the banana itself
	_add_tube(st,
		[Vector3(0.0, 0.0, 47.0), Vector3(0.0, -1.0, 54.0), Vector3(0.0, -3.0, 61.0), Vector3(0.0, -6.5, 67.0), Vector3(0.0, -11.0, 70.5)],
		[2.6, 3.5, 3.7, 3.1, 1.2], yellow, brown)

	# three peel flaps, same azimuths as the bone chains
	for az_deg in [-35.5, -145.0, 97.8]:
		var az := deg_to_rad(az_deg)
		var out := Vector3(cos(az), sin(az), 0.0)
		var across := Vector3(-sin(az), cos(az), 0.0)
		var rs := [1.5, 5.0, 9.0, 12.5, 15.0]
		var zs := [52.0, 49.0, 44.5, 39.0, 34.5]
		var ws := [3.2, 3.6, 3.4, 2.8, 1.8]
		var spine:Array = []
		for i in rs.size():
			spine.append(out * rs[i] + Vector3(0.0, 0.0, zs[i]))
		_add_ribbon(st, spine, ws, across, yellow, brown)

	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 0.6
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = "Banana"
	mi.mesh = mesh
	return mi

func _vtx(st:SurfaceTool, p:Vector3, n:Vector3, c:Color) -> void:
	st.set_color(c)
	st.set_normal(n)
	st.add_vertex(p)

func _add_tube(st:SurfaceTool, pts:Array, radii:Array, col:Color, tip:Color) -> void:
	var sides := 10
	var rings:Array = []
	for i in pts.size():
		var tangent:Vector3
		if i == 0:
			tangent = pts[1] - pts[0]
		elif i == pts.size() - 1:
			tangent = pts[i] - pts[i - 1]
		else:
			tangent = pts[i + 1] - pts[i - 1]
		tangent = tangent.normalized()
		var ref := Vector3.RIGHT if absf(tangent.dot(Vector3.RIGHT)) < 0.9 else Vector3.UP
		var nx := tangent.cross(ref).normalized()
		var ny := tangent.cross(nx).normalized()
		var ring:Array = []
		for s in sides:
			var a := TAU * float(s) / float(sides)
			var dir := nx * cos(a) + ny * sin(a)
			var pos:Vector3 = pts[i]
			ring.append([pos + dir * float(radii[i]), dir])
		rings.append(ring)
	for i in range(pts.size() - 1):
		var c0 := tip if i == 0 else col
		var c1 := tip if i == pts.size() - 2 else col
		var r0:Array = rings[i]
		var r1:Array = rings[i + 1]
		for s in sides:
			var s2 := (s + 1) % sides
			var a0:Array = r0[s]
			var b0:Array = r0[s2]
			var a1:Array = r1[s]
			var b1:Array = r1[s2]
			_vtx(st, a0[0], a0[1], c0)
			_vtx(st, b0[0], b0[1], c0)
			_vtx(st, b1[0], b1[1], c1)
			_vtx(st, a0[0], a0[1], c0)
			_vtx(st, b1[0], b1[1], c1)
			_vtx(st, a1[0], a1[1], c1)
	# close the tip
	var last:Array = rings[rings.size() - 1]
	var tip_center:Vector3 = pts[pts.size() - 1]
	var tip_dir:Vector3 = (pts[pts.size() - 1] - pts[pts.size() - 2]).normalized()
	for s in sides:
		var a:Array = last[s]
		var b:Array = last[(s + 1) % sides]
		_vtx(st, tip_center, tip_dir, tip)
		_vtx(st, a[0], tip_dir, tip)
		_vtx(st, b[0], tip_dir, tip)

func _add_ribbon(st:SurfaceTool, spine:Array, widths:Array, across:Vector3, col:Color, tip:Color) -> void:
	for i in range(spine.size() - 1):
		var p0:Vector3 = spine[i]
		var p1:Vector3 = spine[i + 1]
		var w0 := float(widths[i]) * 0.5
		var w1 := float(widths[i + 1]) * 0.5
		var n := (p1 - p0).cross(across).normalized()
		var c0 := col
		var c1 := tip if i == spine.size() - 2 else col
		var a0 := p0 - across * w0
		var b0 := p0 + across * w0
		var a1 := p1 - across * w1
		var b1 := p1 + across * w1
		_vtx(st, a0, n, c0)
		_vtx(st, b0, n, c0)
		_vtx(st, b1, n, c1)
		_vtx(st, a0, n, c0)
		_vtx(st, b1, n, c1)
		_vtx(st, a1, n, c1)
