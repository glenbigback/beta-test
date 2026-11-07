extends Node3D
# The Stump's cosmetics room: touch a button with your hand and you wear that item (touch it again to
# take it off). You see it on yourself in the mirror, exactly like Gorilla Tag.
#
# Like the real game:
#   - one item per slot: a hat, a face item, and a badge (touching another hat swaps hats),
#   - the button of whatever you are wearing stays lit (the map's red "pressed" look),
#   - touching a button buzzes your controller,
#   - the item sits on your head exactly like it sits on its display head on the shelf: placement is
#     copied from the map's own display heads, so hats/glasses are where Gorilla Tag puts them.
# Your own view never shows your hat (it would be in your face); only the mirror copy does.
#
# The map's FBX has no mesh for the banana hat (only its bones), so a banana hat is built in code.

const CATALOG := {
	"Cowboy_Hat_Button": {"label": "COWBOY HAT", "text": "Cowboy_Text", "head": "cowboyhatmodel", "item": "cowboyhat", "slot": "hat"},
	"Fez_Button": {"label": "FEZ", "text": "Fez_Text", "head": "fezmodel", "item": "fez", "slot": "hat"},
	"Top_Hat_Button": {"label": "TOP HAT", "text": "Tophat_Text", "head": "tophatmodel", "item": "tophat", "slot": "hat"},
	"Sunhat_Button": {"label": "SUN HAT", "text": "Sunhat_Text", "head": "sunhat_model", "item": "sunhat__1_", "slot": "hat"},
	"Bananahat_Button": {"label": "BANANA HAT", "text": "Bananahat_Text", "head": "bananahat_model", "item": "", "slot": "hat"},
	"Cloche_Button": {"label": "CLOCHE", "text": "Cloche_Text", "head": "cloche_model", "item": "cloche__1_", "slot": "hat"},
	"Coconut_Button": {"label": "COCONUT", "text": "Coconut_Text", "head": "coconut_model", "item": "coconut", "slot": "hat"},
	"Sunglasses_Button": {"label": "SUNGLASSES", "text": "Sunglasses_Text", "head": "sunglasses_model", "item": "sunglasses", "slot": "face"},
	"SunglassesF_Badge": {"label": "SUNGLASSES F", "text": "Sunglassesf_Text", "head": "sunglassesf", "item": "sunglassesf__1_", "slot": "face"},
	"Early_Access_Badge": {"label": "EARLY ACCESS", "text": "Early_Access_Text", "head": "early_access_model", "item": "earlyaccess", "slot": "badge"},
}

# Measurements of the player model (Models/GorillaPlayer), in the model's own units.
const PLAYER_HEAD_SIZE := Vector3(0.274, 0.327, 0.269) # width, height, depth
const PLAYER_HEAD_TOP := 0.653
const PLAYER_HEAD_FRONT := 0.166 # z of the face
const PLAYER_HEAD_CENTER_Z := 0.031
const PLAYER_EYE_Y := 0.46
const PLAYER_FACE_Z := 0.152 # z of the most forward face surface inside the lens area (measured on the model: the nose bridge at the bottom edge of the lenses; the cheeks curve back to ~0.125)

@export var press_cooldown:float = 0.4 # seconds before the same button can be pressed again
@export var touch_reach:float = 0.05 # metres around a button that count as touching it
@export var haptic_amplitude:float = 0.7
@export var show_labels:bool = true
@export var banana_hat:bool = true
@export var banana_scale:float = 0.8 # size of the banana hat, relative to the head (0.45 was only ~9 cm tall; 0.8 is ~16 cm)
@export var badge_width:float = 0.13 # model units: how wide the badge is on your chest
@export var badge_position:Vector3 = Vector3(0.0, 0.2, 0.14) # where the badge hangs (model units: x left, y up, z forward)
@export var face_offset:Vector3 = Vector3.ZERO # nudge glasses: x = your left, y = up, z = forward (metres in model units)
@export var face_gap:float = 0.004 # how far in front of the face the lenses sit
@export var face_scale_multiplier:float = 1.0 # make glasses bigger (>1) or smaller (<1)
# Tweaks if something sits a little off on your gorilla:
@export var hat_scale_multiplier:float = 1.0
@export var hat_yaw_offset_deg:float = 0.0 # set to 180 if hats ever face backwards
@export var hat_offset:Vector3 = Vector3.ZERO # model units: x = your left, y = up, z = forward

var _body:Node
var _hands:Array = []
var _ctrls:Array = []
var _entries:Array = []
var _equipped := {} # slot -> button name
var _pressed_mat:StandardMaterial3D
var _frame := {}

func setup(map:Node, player_container:Node3D, body:Node, front_hint:Vector3) -> void:
	_body = body
	_hands = [player_container.get_node_or_null("LeftHandFollower"), player_container.get_node_or_null("RightHandFollower")]
	_ctrls = [player_container.get_node_or_null("Player/XROrigin3D/LeftHand"), player_container.get_node_or_null("Player/XROrigin3D/RightHand")]
	_pressed_mat = StandardMaterial3D.new()
	_pressed_mat.albedo_color = Color(1.0, 0.0, 0.0) # the map's own "pressed" material colour
	_pressed_mat.roughness = 0.5
	var root := map.find_child("Cosmetics", true, false)
	if root == null:
		push_warning("Cosmetics: 'Cosmetics' node not found in the map")
		return
	for key in CATALOG:
		var key_s:String = key
		var info:Dictionary = CATALOG[key_s]
		var btn := root.find_child(key_s, false, false) as MeshInstance3D
		var head := map.find_child(info.head, true, false) as MeshInstance3D
		if btn == null or head == null:
			push_warning("Cosmetics: missing button or display head for " + key_s)
			continue
		if _frame.is_empty():
			_frame = _head_frame(head)
		var item:Node3D = null
		if key_s == "Bananahat_Button":
			if banana_hat:
				item = _build_banana(head)
		else:
			item = head.find_child(info.item, true, false) as Node3D
		var scale3 := btn.global_transform.basis.get_scale()
		var m := Vector3(touch_reach / scale3.x, touch_reach / scale3.y, touch_reach / scale3.z)
		var grown := btn.get_aabb()
		grown.position -= m
		grown.size += m * 2.0
		var entry := {
			"name": key_s, "slot": info.slot, "btn": btn, "item": item, "grown": grown,
			"inv": btn.global_transform.affine_inverse(), "cooldown": 0.0, "inside": [false, false],
			"xform": Transform3D.IDENTITY,
		}
		if item != null:
			entry.xform = _model_xform(head, item, info.slot)
		_entries.append(entry)
		if show_labels:
			_make_label(entry, btn, info.label, root.find_child(info.text, true, false) as Node3D, front_hint)

func _process(delta:float) -> void:
	for e in _entries:
		e.cooldown = maxf(0.0, e.cooldown - delta)
	for h in _hands.size():
		var hand := _hands[h] as Node3D
		if hand == null:
			continue
		var hp := hand.global_position
		for e in _entries:
			var local:Vector3 = e.inv * hp
			var inside:bool = e.grown.has_point(local)
			if inside and not e.inside[h] and e.cooldown <= 0.0:
				e.cooldown = press_cooldown
				_press(e, h)
			e.inside[h] = inside

func _press(e:Dictionary, hand:int) -> void:
	var ctrl := _ctrls[hand] as XRController3D
	if ctrl != null:
		ctrl.trigger_haptic_pulse("haptic", 0.0, haptic_amplitude, 0.1, 0.0)
	if e.item == null or _body == null:
		return
	var slot:String = e.slot
	var was:String = _equipped.get(slot, "")
	if was != "":
		_set_pressed(was, false)
		_body.unequip_cosmetic(slot)
		_equipped.erase(slot)
	if was == e.name:
		return # touching what you are wearing takes it off
	var copy:Node3D = (e.item as Node3D).duplicate()
	# the display copies carry map collision; a worn item must not push your hands around
	for c in copy.find_children("*", "CollisionObject3D", true, false):
		c.get_parent().remove_child(c)
		c.queue_free()
	_body.equip_cosmetic(slot, copy, e.xform)
	_equipped[slot] = e.name
	_set_pressed(e.name, true)

func _set_pressed(btn_name:String, on:bool) -> void:
	for e in _entries:
		if e.name == btn_name:
			(e.btn as MeshInstance3D).material_override = _pressed_mat if on else null

# ---------------------------------------------------------------------------------------------
# Placement: map the display head's frame onto the player's head.
# ---------------------------------------------------------------------------------------------

# Which of the display head's local axes is up / forward / right. In the FBX the head is built Z-up
# and faces -Y (verified: all ten display heads face the room centre); if the importer re-oriented it
# to Y-up it faces +Z.
func _head_frame(head:MeshInstance3D) -> Dictionary:
	var b := head.global_transform.basis
	var axes := [b.x.normalized(), b.y.normalized(), b.z.normalized()]
	var up_i := 2
	var best := -1.0
	for i in 3:
		var d := absf((axes[i] as Vector3).dot(Vector3.UP))
		if d > best:
			best = d
			up_i = i
	if up_i == 2:
		return {"right": Vector3(-1, 0, 0), "fwd": Vector3(0, -1, 0), "up": Vector3(0, 0, 1), "ri": 0, "fi": 1, "ui": 2}
	return {"right": Vector3(-1, 0, 0), "fwd": Vector3(0, 0, 1), "up": Vector3(0, 1, 0), "ri": 0, "fi": 2, "ui": 1}

# Display-head-local point on top of the head, centred.
func _top_anchor(head:MeshInstance3D) -> Vector3:
	var aabb := head.get_aabb()
	var a := aabb.get_center()
	a[_frame.ui as int] = aabb.end[_frame.ui as int]
	return a

func _item_aabb(head:Node3D, item:Node3D) -> AABB:
	var inv := head.global_transform.affine_inverse()
	var result := AABB()
	var first := true
	var nodes:Array = [item]
	nodes.append_array(item.find_children("*", "MeshInstance3D", true, false))
	for n in nodes:
		var mi := n as MeshInstance3D
		if mi != null and mi.mesh != null:
			var a:AABB = (inv * mi.global_transform) * mi.get_aabb()
			result = a if first else result.merge(a)
			first = false
	return result

# Where the item goes in the player model's space.
func _model_xform(head:MeshInstance3D, item:Node3D, slot:String) -> Transform3D:
	var ri:int = _frame.ri
	var fi:int = _frame.fi
	var ui:int = _frame.ui
	var aabb := head.get_aabb()
	var k := (PLAYER_HEAD_SIZE.x / aabb.size[ri] + PLAYER_HEAD_SIZE.y / aabb.size[ui] + PLAYER_HEAD_SIZE.z / aabb.size[fi]) / 3.0
	k *= hat_scale_multiplier
	var r_dl := Basis(_frame.right as Vector3, _frame.up as Vector3, -(_frame.fwd as Vector3))
	var r_pl := Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, -1)) # player: faces +Z, up +Y
	var a_d := aabb.get_center()
	var a_p:Vector3
	if slot == "badge":
		# badge: hangs on the chest, sized by its own width, same facing as on the display head
		var ba := _item_aabb(head, item)
		k = badge_width / maxf(ba.size[ri], 0.000001)
		a_d = ba.get_center()
		a_p = badge_position
	elif slot == "face":
		# glasses: lenses on the face, centred on the eyes
		# sized by the head WIDTH (glasses span the face), lens front sits just in front of the face at eye height
		var ia := _item_aabb(head, item)
		k = PLAYER_HEAD_SIZE.x / aabb.size[ri] * face_scale_multiplier
		a_d[ui] = ia.get_center()[ui]
		a_d[ri] = ia.get_center()[ri]
		var fwd_neg:bool = (_frame.fwd as Vector3)[fi] < 0.0
		a_d[fi] = ia.position[fi] if fwd_neg else ia.end[fi] # the front of the lenses, not of the head
		a_p = Vector3(0.0, PLAYER_EYE_Y, PLAYER_FACE_Z + face_gap) + face_offset
	else:
		# hats and badges: keep the same height below the top of the head
		a_d = _top_anchor(head)
		a_d[fi] = aabb.get_center()[fi]
		a_p = Vector3(0.0, PLAYER_HEAD_TOP, PLAYER_HEAD_CENTER_Z)
	var rel := head.global_transform.affine_inverse() * item.global_transform
	var yaw := Basis(Vector3.UP, deg_to_rad(hat_yaw_offset_deg))
	var map_basis := (r_pl * r_dl.inverse()).scaled(Vector3.ONE * k)
	return Transform3D(Basis(), a_p + hat_offset) * Transform3D(yaw, Vector3.ZERO) * Transform3D(map_basis, Vector3.ZERO) * Transform3D(Basis(), -a_d) * rel

# ---------------------------------------------------------------------------------------------
# Button labels (the map's TextMeshPro text did not survive the FBX export)
# ---------------------------------------------------------------------------------------------

func _make_label(entry:Dictionary, btn:MeshInstance3D, text:String, text_node:Node3D, front_hint:Vector3) -> void:
	if btn.mesh == null:
		return
	var xf := btn.global_transform
	var center := xf * btn.get_aabb().get_center()
	var target := text_node.global_position if text_node != null else front_hint
	var dir := (target - center).normalized()
	var tris := btn.mesh.get_faces()
	var faces:Array = []
	var best_n := Vector3.ZERO
	var best := -2.0
	for k in range(0, tris.size() - 2, 3):
		var a := xf * tris[k]
		var b := xf * tris[k + 1]
		var c := xf * tris[k + 2]
		var cr := (b - a).cross(c - a)
		if cr.length_squared() < 0.0000000001:
			continue
		var n := cr.normalized()
		var tc := (a + b + c) / 3.0
		if n.dot(tc - center) < 0.0:
			n = -n
		faces.append([n, tc, cr.length() * 0.5])
		if n.dot(dir) > best:
			best = n.dot(dir)
			best_n = n
	if best_n == Vector3.ZERO:
		return
	var fc := Vector3.ZERO
	var area := 0.0
	for f in faces:
		if (f[0] as Vector3).dot(best_n) > 0.98:
			fc += (f[1] as Vector3) * (f[2] as float)
			area += f[2] as float
	if area <= 0.0:
		return
	fc /= area
	var side := sqrt(area) # a button face is a square
	var z := best_n
	var y := (Vector3.UP - z * z.dot(Vector3.UP))
	if y.length() < 0.1:
		y = Vector3.FORWARD
	y = y.normalized()
	var x := y.cross(z)
	var label := Label3D.new()
	label.text = text
	label.font_size = 28
	label.width = 200.0
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.pixel_size = side * 0.92 / 200.0
	label.modulate = Color(0.05, 0.05, 0.05)
	label.outline_size = 0
	add_child(label)
	label.global_transform = Transform3D(Basis(x, y, z), fc + z * 0.002)

# ---------------------------------------------------------------------------------------------
# Banana hat (a half-peeled banana: yellow body, three peel strips drooping down)
# ---------------------------------------------------------------------------------------------

func _build_banana(head:MeshInstance3D) -> Node3D:
	var root := Node3D.new()
	root.name = "BananaHatMesh"
	var yellow := StandardMaterial3D.new()
	yellow.albedo_color = Color(0.98, 0.82, 0.12)
	yellow.roughness = 0.55
	yellow.cull_mode = BaseMaterial3D.CULL_DISABLED
	var brown := StandardMaterial3D.new()
	brown.albedo_color = Color(0.22, 0.15, 0.07)
	brown.roughness = 0.8
	brown.cull_mode = BaseMaterial3D.CULL_DISABLED
	# a slim banana: gently curved tube
	var pts:Array = []
	var rad:Array = []
	var steps := 12
	for i in steps + 1:
		var s := float(i) / steps
		pts.append(Vector3(6.0 * s * s, 1.0 + 24.0 * s, 0.0))
		rad.append(1.0 + 0.9 * sin(PI * s))
	root.add_child(_tube(pts, rad, 8, yellow))
	var stem_pts:Array = [Vector3(6.0, 25.0, 0.0), Vector3(6.4, 27.5, 0.0)]
	root.add_child(_tube(stem_pts, [0.8, 0.6], 6, brown))
	# three narrow peel strips that stay close to the banana (so they stay on the head)
	for k in 3:
		root.add_child(_ribbon(TAU * float(k) / 3.0 + 0.5, yellow))
	head.add_child(root)
	# build units are "centimetres on a 41.6 cm head"; follow the head's real size so the hat is the right
	# size however the importer scaled the mesh
	var unit := head.get_aabb().size[_frame.ui as int] / 41.6
	root.transform = Transform3D(Basis(_frame.right as Vector3, _frame.up as Vector3, -(_frame.fwd as Vector3)).scaled(Vector3.ONE * banana_scale * unit), _top_anchor(head))
	return root

func _tri(st:SurfaceTool, a:Vector3, b:Vector3, c:Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)

func _tube(pts:Array, rad:Array, sides:int, mat:Material) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings:Array = []
	for i in pts.size():
		var a:Vector3 = pts[maxi(i - 1, 0)]
		var b:Vector3 = pts[mini(i + 1, pts.size() - 1)]
		var t := (b - a).normalized()
		var nrm := Vector3(-t.y, t.x, 0.0).normalized()
		var ring:Array = []
		for j in sides:
			var ang := TAU * float(j) / sides
			ring.append((pts[i] as Vector3) + (nrm * cos(ang) + Vector3(0, 0, 1) * sin(ang)) * (rad[i] as float))
		rings.append(ring)
	for i in pts.size() - 1:
		for j in sides:
			var j2 := (j + 1) % sides
			var p00:Vector3 = rings[i][j]
			var p01:Vector3 = rings[i][j2]
			var p10:Vector3 = rings[i + 1][j]
			var p11:Vector3 = rings[i + 1][j2]
			_tri(st, p00, p10, p01)
			_tri(st, p01, p10, p11)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	return mi

func _ribbon(phi:float, mat:Material) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var radial := Vector3(cos(phi), 0.0, sin(phi))
	var tang := Vector3(-sin(phi), 0.0, cos(phi))
	var n := 8
	var prev_l := Vector3.ZERO
	var prev_r := Vector3.ZERO
	for i in n + 1:
		var t := float(i) / n
		var c := radial * (1.4 + 6.0 * t) + Vector3(0.0, 0.6 + 4.5 * t - 8.5 * t * t, 0.0) # arcs out then droops onto the skull
		var w := 1.1 - 0.5 * t
		var l := c - tang * w
		var r := c + tang * w
		if i > 0:
			_tri(st, prev_l, prev_r, l)
			_tri(st, prev_r, r, l)
		prev_l = l
		prev_r = r
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	return mi
