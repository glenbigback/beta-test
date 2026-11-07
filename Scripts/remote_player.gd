extends Node3D
# Another player in your room. It is the same gorilla model with the same two-bone arm IK as you
# (Scripts/gorilla_body.gd); instead of your headset and controllers it follows the pose the server
# relays. To reuse gorilla_body.gd unchanged, this node builds the little rig that script expects
# (Player/XROrigin3D/Head, LeftHand, RightHand, LeftHandFollower, RightHandFollower) out of plain Node3Ds.
#
# Pose layout (21 floats, same as player.gd get_net_pose()):
#   0-2 head position   3-6 head rotation (xyzw)   7-10 left controller rotation   11-14 right controller rotation
#   15-17 left hand position   18-20 right hand position   (all world space)

const BodyScript := preload("res://Scripts/gorilla_body.gd")
const SMOOTHING := 18.0 # 1/s: higher = snappier, lower = smoother (hides the 20 Hz update rate)
const SNAP_DISTANCE := 3.0 # farther than this in one update = teleport / respawn, do not glide
const NAME_HEIGHT := 0.45 # metres above the head

var peer_id:int = -1
var player_name:String = "GORILLA"
var body # GorillaBody node (script instance)
var label:Label3D

var _head:Node3D
var _left_ctrl:Node3D
var _right_ctrl:Node3D
var _left_hand:Node3D
var _right_hand:Node3D
var _color = null # Color or null (null = the model's own colour)

var _have_pose := false
var _head_pos := Vector3.ZERO
var _head_q := Quaternion.IDENTITY
var _lq := Quaternion.IDENTITY
var _rq := Quaternion.IDENTITY
var _lh := Vector3.ZERO
var _rh := Vector3.ZERO
var _t_head_pos := Vector3.ZERO
var _t_head_q := Quaternion.IDENTITY
var _t_lq := Quaternion.IDENTITY
var _t_rq := Quaternion.IDENTITY
var _t_lh := Vector3.ZERO
var _t_rh := Vector3.ZERO

# Call once, before the node is added to the tree.
func setup(id:int, pname:String, col) -> void:
	peer_id = id
	player_name = pname
	_color = col

	var player := Node3D.new()
	player.name = "Player"
	add_child(player)
	var origin := Node3D.new()
	origin.name = "XROrigin3D"
	player.add_child(origin)
	_head = _make_node("Head", origin)
	_left_ctrl = _make_node("LeftHand", origin)
	_right_ctrl = _make_node("RightHand", origin)
	_left_hand = _make_node("LeftHandFollower", self)
	_right_hand = _make_node("RightHandFollower", self)

	label = Label3D.new()
	label.text = pname
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 48
	label.pixel_size = 0.004
	label.outline_size = 10
	label.shaded = false
	add_child(label)

	# added last: its _ready() looks up the nodes above by path
	body = BodyScript.new()
	body.name = "GorillaBody"
	body.hide_own_head = false # other people see this gorilla's face
	body.make_mirror_copy = false # no mirror double needed for other players
	add_child(body)

	visible = false # until the first pose arrives

func _make_node(node_name:String, parent:Node) -> Node3D:
	var n := Node3D.new()
	n.name = node_name
	parent.add_child(n)
	return n

func _ready() -> void:
	if _color != null:
		body.set_gorilla_color(_color)

func set_profile(pname:String, col) -> void:
	player_name = pname
	if label != null:
		label.text = pname
	_color = col
	if is_node_ready() and col != null:
		body.set_gorilla_color(col)

func _quat(p:PackedFloat32Array, i:int) -> Quaternion:
	var q := Quaternion(p[i], p[i + 1], p[i + 2], p[i + 3])
	if q.length() < 0.5:
		return Quaternion.IDENTITY
	return q.normalized()

func set_pose(p:PackedFloat32Array) -> void:
	if p.size() != 21:
		return
	_t_head_pos = Vector3(p[0], p[1], p[2])
	_t_head_q = _quat(p, 3)
	_t_lq = _quat(p, 7)
	_t_rq = _quat(p, 11)
	_t_lh = Vector3(p[15], p[16], p[17])
	_t_rh = Vector3(p[18], p[19], p[20])
	if not _have_pose or _head_pos.distance_to(_t_head_pos) > SNAP_DISTANCE:
		_head_pos = _t_head_pos
		_head_q = _t_head_q
		_lq = _t_lq
		_rq = _t_rq
		_lh = _t_lh
		_rh = _t_rh
		_have_pose = true
		visible = true

func _process(delta:float) -> void:
	if not _have_pose:
		return
	var k := 1.0 - exp(-SMOOTHING * delta)
	_head_pos = _head_pos.lerp(_t_head_pos, k)
	_head_q = _head_q.slerp(_t_head_q, k)
	_lq = _lq.slerp(_t_lq, k)
	_rq = _rq.slerp(_t_rq, k)
	_lh = _lh.lerp(_t_lh, k)
	_rh = _rh.lerp(_t_rh, k)

	_head.global_transform = Transform3D(Basis(_head_q), _head_pos)
	_left_ctrl.global_transform = Transform3D(Basis(_lq), _lh)
	_right_ctrl.global_transform = Transform3D(Basis(_rq), _rh)
	_left_hand.global_position = _lh
	_right_hand.global_position = _rh
	label.global_position = _head_pos + Vector3(0.0, NAME_HEIGHT, 0.0)
