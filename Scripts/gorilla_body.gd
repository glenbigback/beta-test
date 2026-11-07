extends Node3D
# Gorilla Tag player model ("Gorilla tag Player model" by S3ntaGT, CC-BY-4.0, see Models/GorillaPlayer/license.txt).
#
# - The body hangs under your headset: the model's eyes are placed on the XR camera and it turns
#   (yaw only) to follow where you look.
# - Each arm is solved with two-bone IK so the wrist reaches the hand follower, i.e. the arms follow
#   your controllers and rest ON walls/floors instead of sinking into them (same position the old
#   sphere hands used).
# - Like Gorilla Tag the arms STRETCH: if your hand is stuck on a wall/floor while your body moves
#   away, the arm gets longer instead of the hand letting go.
# - The hands rotate with your controllers.
# - Your own head is hidden (shrunk to nothing) so it never blocks your view.

@export var model_scene:PackedScene = preload("res://Models/GorillaPlayer/scene.gltf")
@export var model_scale:float = 0.75 # the raw model is ~1.27 units tall with ~0.95 long arms; 0.75 gives human-sized arms
@export var hide_own_head:bool = true
@export var hide_hand_spheres:bool = true # hide the debug spheres that used to be the hands
@export var yaw_follow_speed:float = 10.0 # how fast the body turns to face where you look
@export var eye_from_head_bone:Vector3 = Vector3(0.0, 0.105, 0.155) # eye position relative to the head bone (model units)
@export var stretch_arms:bool = true
@export var max_arm_stretch:float = 2.0 # arm length multiplier at full stretch (1 = rigid arms)
@export var rotate_hands:bool = true # hands follow controller rotation
@export var hand_rotation_offset_deg:Vector3 = Vector3.ZERO # tweak how the hands sit on the controllers (degrees, controller space)
@export var wrist_offset:Vector3 = Vector3.ZERO # shift the wrist target, in the follower's local space
@export var elbow_pole_left:Vector3 = Vector3(0.6, -0.2, -1.0) # which way the left elbow bends (skeleton space, +Z is the model's front)
@export var elbow_pole_right:Vector3 = Vector3(-0.6, -0.2, -1.0)

# Maps the controller's axes onto the model's resting hand (fingers down, thumb forward, palm to the
# body) so a controller held in its natural pose gives the resting hand. Same for both hands.
const CONTROLLER_TO_REST := Basis(Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0))

# Visual layers: 1 = the world, 2 = the mirror's copy of you (has a head + cosmetics),
# 3 = your own first-person body (head hidden). Your headset camera skips layer 2, the mirror camera skips 3.
const LAYER_MIRROR_BODY := 2
const LAYER_OWN_BODY := 4

var head:Node3D
var mirror_model:Node3D
var mirror_skeleton:Skeleton3D
var _cosmetics := {} # slot -> BoneAttachment3D on the mirror copy's head
var left_target:Node3D
var right_target:Node3D
var left_ctrl:Node3D
var right_ctrl:Node3D
var model:Node3D
var skeleton:Skeleton3D

var head_bone := -1
var arms := [] # [{upper, lower, wrist, parent, l1, l2, pole, target}]
var eye_local := Vector3.ZERO # eye point in body space (before scaling)
var body_yaw:float = 0.0
var _have_yaw := false

func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	head = get_node("../Player/XROrigin3D/Head")
	left_target = get_node("../LeftHandFollower")
	right_target = get_node("../RightHandFollower")
	left_ctrl = get_node("../Player/XROrigin3D/LeftHand")
	right_ctrl = get_node("../Player/XROrigin3D/RightHand")

	if hide_hand_spheres:
		for f in [left_target, right_target]:
			var m := f.get_node_or_null("CollisionShape3D/MeshInstance3D") as Node3D
			if m:
				m.visible = false

	model = model_scene.instantiate()
	add_child(model)
	var skeletons := model.find_children("*", "Skeleton3D", true, false)
	if skeletons.is_empty():
		push_warning("GorillaBody: no Skeleton3D found in the model")
		return
	skeleton = skeletons[0]

	# skinned meshes are culled with their bind-pose box; the arms stretch far outside it
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).extra_cull_margin = 2.0

	head_bone = _find_bone("head")
	arms = [
		_make_arm("upperarml", "lowerarml", "wristl", left_target, left_ctrl, elbow_pole_left),
		_make_arm("upperarmr", "lowerarmr", "wristr", right_target, right_ctrl, elbow_pole_right),
	]
	if head_bone >= 0:
		var head_rest := skeleton.global_transform * skeleton.get_bone_global_rest(head_bone).origin
		eye_local = global_transform.affine_inverse() * head_rest + eye_from_head_bone
		if hide_own_head:
			skeleton.set_bone_pose_scale(head_bone, Vector3.ONE * 0.001)
	_make_mirror_copy()

# A second copy of the gorilla that only the mirror camera can see. Same pose every frame, but its head
# is NOT hidden and it carries the cosmetics you equip.
func _make_mirror_copy() -> void:
	mirror_model = model_scene.instantiate()
	mirror_model.name = "MirrorModel"
	add_child(mirror_model)
	var skels := mirror_model.find_children("*", "Skeleton3D", true, false)
	if skels.is_empty():
		mirror_model.queue_free()
		mirror_model = null
		return
	mirror_skeleton = skels[0]
	for mi in mirror_model.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		m.layers = LAYER_MIRROR_BODY
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		m.extra_cull_margin = 2.0
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).layers = LAYER_OWN_BODY
	var cam := head as Camera3D
	if cam != null:
		cam.cull_mask = 0xFFFFF & ~LAYER_MIRROR_BODY

func _sync_mirror_pose() -> void:
	if mirror_skeleton == null:
		return
	for i in skeleton.get_bone_count():
		mirror_skeleton.set_bone_pose_position(i, skeleton.get_bone_pose_position(i))
		mirror_skeleton.set_bone_pose_rotation(i, skeleton.get_bone_pose_rotation(i))
		mirror_skeleton.set_bone_pose_scale(i, skeleton.get_bone_pose_scale(i))
	if head_bone >= 0:
		mirror_skeleton.set_bone_pose_scale(head_bone, Vector3.ONE)

# Put a cosmetic on the mirror copy's head. model_xform is where it goes in the gorilla model's own
# space (the space of the model's mesh vertices, see _head_bind). One item per slot ("hat", "face", "badge").
func equip_cosmetic(slot:String, item:Node3D, model_xform:Transform3D) -> void:
	unequip_cosmetic(slot)
	if mirror_skeleton == null or head_bone < 0:
		item.queue_free()
		return
	var att := BoneAttachment3D.new()
	att.name = "Cosmetic_" + slot
	mirror_skeleton.add_child(att)
	att.bone_name = mirror_skeleton.get_bone_name(head_bone)
	att.add_child(item)
	item.transform = _head_bind() * model_xform
	_set_layers(item)
	_cosmetics[slot] = att

# Matrix that takes a point in the gorilla model's own (mesh vertex) space into the head bone's local
# space. It is the skin's bind pose for the head bone -- the very matrix the engine uses to skin the head
# mesh -- so a cosmetic placed with it sits exactly where the head mesh is. (The bone's rest pose is NOT
# the same thing: this model's skeleton carries a small offset from its mesh space, which shifted every
# hat / pair of glasses a couple of centimetres.) Falls back to the rest pose if no skin is found.
func _head_bind() -> Transform3D:
	var fallback := mirror_skeleton.get_bone_global_rest(head_bone).affine_inverse()
	if mirror_model == null:
		return fallback
	var bone_name := String(mirror_skeleton.get_bone_name(head_bone))
	for node in mirror_model.find_children("*", "MeshInstance3D", true, false):
		var skin:Skin = (node as MeshInstance3D).skin
		if skin == null:
			continue
		for i in skin.get_bind_count():
			var bind_name := String(skin.get_bind_name(i))
			if (bind_name != "" and bind_name == bone_name) or (bind_name == "" and skin.get_bind_bone(i) == head_bone):
				return skin.get_bind_pose(i)
	return fallback

func unequip_cosmetic(slot:String) -> void:
	if _cosmetics.has(slot):
		var a:Node = _cosmetics[slot]
		if is_instance_valid(a):
			a.queue_free()
		_cosmetics.erase(slot)

func _set_layers(n:Node) -> void:
	if n is MeshInstance3D:
		(n as MeshInstance3D).layers = LAYER_MIRROR_BODY
		(n as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in n.get_children():
		_set_layers(c)

# Bone names can come out as "Upper Arm R_6" or "Upper_Arm_R_6" depending on the importer, so compare
# lower-cased with everything but letters/digits stripped ("upperarmr6") and match by prefix.
func _find_bone(prefix:String) -> int:
	for i in skeleton.get_bone_count():
		var n := ""
		for ch in skeleton.get_bone_name(i).to_lower():
			if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
				n += ch
		if n.begins_with(prefix):
			return i
	push_warning("GorillaBody: bone '%s' not found" % prefix)
	return -1

func _make_arm(upper:String, lower:String, wrist:String, target:Node3D, ctrl:Node3D, pole:Vector3) -> Dictionary:
	var u := _find_bone(upper)
	var l := _find_bone(lower)
	var w := _find_bone(wrist)
	if u < 0 or l < 0 or w < 0:
		return {}
	var ru := skeleton.get_bone_global_rest(u).origin
	var rl := skeleton.get_bone_global_rest(l).origin
	var rw := skeleton.get_bone_global_rest(w).origin
	return {
		"upper": u, "lower": l, "wrist": w,
		"parent": skeleton.get_bone_parent(u),
		"l1": ru.distance_to(rl), "l2": rl.distance_to(rw),
		"pole": pole.normalized(), "target": target, "ctrl": ctrl,
	}

func _process(delta:float) -> void:
	if skeleton == null or head == null or delta <= 0.0:
		return

	# --- body placement: eyes on the camera, facing where you look (yaw only) ---
	var target_yaw := _head_yaw()
	if not _have_yaw:
		body_yaw = target_yaw
		_have_yaw = true
	else:
		body_yaw = lerp_angle(body_yaw, target_yaw, 1.0 - exp(-yaw_follow_speed * delta))
	# the model faces +Z, Godot's forward is -Z, hence + PI
	var body_basis := Basis(Vector3.UP, body_yaw + PI).scaled(Vector3.ONE * model_scale)
	global_transform = Transform3D(body_basis, head.global_position - body_basis * eye_local)

	# --- arms ---
	for arm in arms:
		if arm.is_empty():
			continue
		_solve_arm(arm)
	_sync_mirror_pose()

# Horizontal direction the head is looking. Looking straight up/down makes forward useless, so
# fall back to the head's up vector there.
func _head_yaw() -> float:
	var hb := head.global_basis
	var f := -hb.z
	var heading := Vector3(f.x, 0.0, f.z)
	if heading.length() < 0.35:
		var u := hb.y
		var uh := Vector3(u.x, 0.0, u.z)
		heading = uh if f.y < 0.0 else -uh
	if heading.length() < 0.001:
		return body_yaw
	heading = heading.normalized()
	return atan2(-heading.x, -heading.z)

func _solve_arm(arm:Dictionary) -> void:
	var tgt:Node3D = arm.target
	var world_t := tgt.global_position + tgt.global_basis * wrist_offset
	var t := skeleton.global_transform.affine_inverse() * world_t

	var rest_u := skeleton.get_bone_global_rest(arm.upper)
	var rest_l := skeleton.get_bone_global_rest(arm.lower)
	var rest_w := skeleton.get_bone_global_rest(arm.wrist)
	var s := rest_u.origin
	var to_t := t - s
	var dist := to_t.length()
	if dist < 0.0001:
		return
	var dir := to_t / dist
	var l1:float = arm.l1
	var l2:float = arm.l2

	# stretch: once the target is (nearly) out of reach, lengthen the whole arm instead of stopping short
	var k := 1.0
	if stretch_arms:
		k = clampf(dist / ((l1 + l2) * 0.98), 1.0, maxf(max_arm_stretch, 1.0))
	l1 *= k
	l2 *= k
	var d := clampf(dist, 0.05, (l1 + l2) * 0.999) # beyond max stretch: straight toward the target

	# law of cosines: elbow sits `a` along the line to the target and `h` off it, toward the pole
	var a := (l1 * l1 - l2 * l2 + d * d) / (2.0 * d)
	var h := sqrt(maxf(l1 * l1 - a * a, 0.0))
	var pole:Vector3 = arm.pole
	var perp := pole - dir * pole.dot(dir)
	if perp.length() < 0.01:
		perp = Vector3.RIGHT - dir * Vector3.RIGHT.dot(dir)
	perp = perp.normalized()
	var elbow := s + dir * a + perp * h
	var wrist := s + dir * d

	# upper arm: swing its bone axis (+Y) from the rest direction onto shoulder -> elbow
	var rest_y_u := (rest_u.basis * Vector3.UP).normalized()
	var want_u := (elbow - s).normalized()
	var upper_rot := Basis(Quaternion(rest_y_u, want_u)) * rest_u.basis.orthonormalized()
	var parent_basis := skeleton.get_bone_global_rest(arm.parent).basis.orthonormalized() if arm.parent >= 0 else Basis()
	skeleton.set_bone_pose_rotation(arm.upper, (parent_basis.inverse() * upper_rot).orthonormalized().get_rotation_quaternion())
	# the stretch lives on the upper arm's length axis; the forearm inherits it, the hand cancels it
	skeleton.set_bone_pose_scale(arm.upper, Vector3(1.0, k, 1.0))
	skeleton.set_bone_pose_scale(arm.lower, Vector3.ONE)
	skeleton.set_bone_pose_scale(arm.wrist, Vector3(1.0, 1.0 / k, 1.0))

	# forearm: swing from rest onto elbow -> wrist, expressed relative to the (stretched) upper arm
	var rest_y_l := (rest_l.basis * Vector3.UP).normalized()
	var want_l := (wrist - elbow).normalized()
	var lower_rot := Basis(Quaternion(rest_y_l, want_l)) * rest_l.basis.orthonormalized()
	var upper_scale_inv := Basis.from_scale(Vector3(1.0, 1.0 / k, 1.0))
	var lower_local := (upper_scale_inv * (upper_rot.inverse() * lower_rot)).orthonormalized()
	skeleton.set_bone_pose_rotation(arm.lower, lower_local.get_rotation_quaternion())

	# hand: follow the controller's rotation (or just stay aligned with the forearm)
	if rotate_hands and arm.ctrl != null:
		var lower_full := upper_rot * Basis.from_scale(Vector3(1.0, k, 1.0)) * lower_local
		var ctrl:Node3D = arm.ctrl
		var ctrl_s := skeleton.global_basis.orthonormalized().inverse() * ctrl.global_basis.orthonormalized()
		var adjust := Basis.from_euler(hand_rotation_offset_deg * (PI / 180.0))
		var target_w := ctrl_s * adjust * CONTROLLER_TO_REST.inverse() * rest_w.basis.orthonormalized()
		var wrist_local := (lower_full.inverse() * target_w).orthonormalized()
		skeleton.set_bone_pose_rotation(arm.wrist, wrist_local.get_rotation_quaternion())
	else:
		skeleton.set_bone_pose_rotation(arm.wrist, skeleton.get_bone_rest(arm.wrist).basis.get_rotation_quaternion())

# Skin colour (set from the Gorilla Computer's COLOR menu): tints the main fur material of both copies.
func set_gorilla_color(c:Color) -> void:
	for root in [model, mirror_model]:
		if root == null:
			continue
		var best:MeshInstance3D = null
		var best_n := -1
		for mi in root.find_children("*", "MeshInstance3D", true, false):
			var m := mi as MeshInstance3D
			if m.mesh == null:
				continue
			var cnt := 0
			for s in m.mesh.get_surface_count():
				cnt += m.mesh.surface_get_array_len(s)
			if cnt > best_n:
				best_n = cnt
				best = m
		if best == null:
			continue
		for s in best.mesh.get_surface_count():
			var mat := best.mesh.surface_get_material(s) as BaseMaterial3D
			if mat == null:
				continue
			var copy := mat.duplicate() as BaseMaterial3D
			copy.albedo_color = c
			best.set_surface_override_material(s, copy)
