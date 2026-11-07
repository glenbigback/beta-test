extends Node

# --- Gorilla locomotion -------------------------------------------------------------------
# Only your ARM MOVEMENT (hand relative to your body) moves you. A hand that is just resting
# on something, or that rides along with your body while you fall, does nothing -- so you can
# no longer stick to / hang from surfaces.
#   floors   : full grip      -> pull your hands back to walk / run
#   walls    : grip with slip -> pull down on a wall to climb it (pull faster than wall_slip_speed)
#   ceilings : push only      -> pushes you away, never holds you

@export var max_jump_speed:float = 7
@export var drag:float = 1
@export var ground_friction:float = 2.0 # 1/s, horizontal slow-down while standing on the floor
@export var jump_multiplier:float = 1
@export var velocity_limit:float = 0.4
@export var velocity_history_size:int = 8
@export var floor_normal_y:float = 0.6 # normal.y at/above this is a floor
@export var ceiling_normal_y:float = -0.3 # normal.y at/below this is a ceiling/overhang (push only)
@export var wall_grip:float = 1.0 # 0..1 how much hand pulling on a wall moves you (1 = full, 0 = walls only push)
@export var wall_slip_speed:float = 0.4 # m/s you slowly slide down while pressing a wall (so you can't hang still). 0 = no slip
@export var press_epsilon:float = 0.0005 # metres of hand motion into a surface per frame needed to count as pressing
@export var max_arm_speed:float = 20.0 # m/s; faster hand motion = tracking glitch, ignored
@export var max_grab_speed:float = 30.0
@export var debug_print_contacts:bool = false # prints which map mesh each hand is pressing on (shows up in the editor Output log)

@onready var player:CharacterBody3D = $Player
@onready var player_collision:CollisionShape3D = $Player/Collision
@onready var head:Node3D = $Player/XROrigin3D/Head
@onready var xr_origin:XROrigin3D = $Player/XROrigin3D
@onready var right_ctrl:XRController3D = $Player/XROrigin3D/RightHand
@onready var left_hand:Node3D = $Player/XROrigin3D/LeftHand/Follow
@onready var right_hand:Node3D = $Player/XROrigin3D/RightHand/Follow
@onready var left_hand_follower:CharacterBody3D = $LeftHandFollower
@onready var right_hand_follower:CharacterBody3D = $RightHandFollower

var velocity_history:Array[Vector3] = []
var previous_position:Vector3
var velocity_average:Vector3
var velocity_index:int

var is_moving:bool

# Turning (set from the Gorilla Computer's TURN menu): right thumbstick.
#   SNAP   = each flick turns you turn_speed * 10 degrees
#   SMOOTH = hold the stick to turn at turn_speed * 20 degrees per second
#   NONE   = thumbstick does nothing
var turn_mode:String = "SNAP"
var turn_speed:int = 5
var _snap_ready := true
var prev_left:Vector3
var prev_right:Vector3

func _ready() -> void:
	add_to_group("gorilla_rig") # Net (net.gd) finds the local rig through this group
	init()

func _process(delta:float) -> void:
	if delta <= 0.0:
		return
	update_body_collision()
	_update_turn(delta)

	if not player.is_on_floor():
		player.velocity += Vector3.DOWN * delta * 9.8
	else:
		player.velocity *= 1.0 - drag * delta
		var flat := Vector3(player.velocity.x, 0.0, player.velocity.z) * clampf(ground_friction * delta, 0.0, 1.0)
		player.velocity -= flat

	var left := hand_push(left_hand, left_hand_follower, prev_left, delta)
	var right := hand_push(right_hand, right_hand_follower, prev_right, delta)
	if left.active or right.active:
		var v:Vector3
		if left.active and right.active:
			v = (left.vel + right.vel) * 0.5
		else:
			v = left.vel if left.active else right.vel
		player.velocity = v.limit_length(max_grab_speed)
		is_moving = true
	elif is_moving:
		# let go: keep your momentum (this is the jump)
		if velocity_average.length() > velocity_limit:
			if velocity_average.length() * jump_multiplier > max_jump_speed:
				player.velocity = velocity_average.normalized() * max_jump_speed
			else:
				player.velocity = jump_multiplier * velocity_average
		elif player.is_on_floor():
			player.velocity = Vector3.ZERO
		else:
			player.velocity = velocity_average
		is_moving = false

	player.move_and_slide()

	prev_left = left_hand.global_position
	prev_right = right_hand.global_position
	left_hand_follower.global_position = surface_position(left_hand_follower, prev_left)
	right_hand_follower.global_position = surface_position(right_hand_follower, prev_right)

	store_velocities(delta)

# Returns {active, vel}: the body velocity this hand asks for this frame.
func hand_push(hand:Node3D, follower:CharacterBody3D, prev:Vector3, delta:float) -> Dictionary:
	var result := {"active": false, "vel": Vector3.ZERO}
	var arm := hand.global_position - prev # how far the hand moved relative to your body this frame
	if arm.length_squared() < 0.0000000001 or arm.length() / delta > max_arm_speed:
		return result
	var col := KinematicCollision3D.new()
	var n := Vector3.ZERO
	var pen := 0.0
	var rem_t := Vector3.ZERO
	var hit:KinematicCollision3D = null
	# 1) sweep from where the hand was to where it is now
	if follower.test_move(Transform3D(Basis(), prev), arm, col, 0.002, true):
		hit = col
		n = col.get_normal()
		var rem := col.get_remainder() # hand motion that went "into" the surface
		pen = maxf(-rem.dot(n), 0.0)
		rem_t = rem - n * rem.dot(n)
	# 2) hand already overlapping a surface (pushed deep in, or dragged while embedded)
	var col2 := KinematicCollision3D.new()
	if follower.test_move(Transform3D(Basis(), hand.global_position), Vector3.ZERO, col2, 0.002, true):
		var n2 := col2.get_normal()
		var depth := col2.get_depth()
		if depth > pen:
			hit = col2
			n = n2
			pen = depth
			rem_t = arm - n2 * arm.dot(n2)
	if pen < press_epsilon or n == Vector3.ZERO:
		return result
	if debug_print_contacts and hit != null:
		_debug_contact(follower, hit)
	var vel_now := player.velocity
	var v_n := maxf(pen / delta, vel_now.dot(n)) # never cancel motion already leaving the surface
	var v_t := vel_now - n * vel_now.dot(n)
	if n.y >= floor_normal_y:
		v_t = -rem_t / delta
	elif n.y > ceiling_normal_y and wall_grip > 0.0:
		var pull := -rem_t / delta
		if wall_slip_speed > 0.0:
			pull += Vector3.DOWN.slide(n).normalized() * wall_slip_speed
		v_t = v_t.lerp(pull, wall_grip)
	result.active = true
	result.vel = n * v_n + v_t
	return result

var _last_contact := {}

func _debug_contact(follower:Node, hit:KinematicCollision3D) -> void:
	var c := hit.get_collider() as Node
	var label := "?"
	if c != null:
		var owner_node := c.get_parent()
		label = str(owner_node.get_path()) if owner_node != null else str(c.get_path())
	if _last_contact.get(follower) != label:
		_last_contact[follower] = label
		print("%s pressing: %s  (normal %s)" % [follower.name, label, hit.get_normal()])

# Where to draw a hand: at the tracked position, but pushed back out of anything it is inside,
# so the visible hand rests ON walls instead of sinking through them.
func surface_position(follower:CharacterBody3D, pos:Vector3) -> Vector3:
	var col := KinematicCollision3D.new()
	for i in 3:
		if follower.test_move(Transform3D(Basis(), pos), Vector3.ZERO, col, 0.001, true):
			pos += col.get_normal() * (col.get_depth() + 0.002)
		else:
			break
	return pos

const BODY_OFFSET := Vector3(0, 0.25, 0)

# The body capsule follows the head. Teleporting it straight to the head puts it inside
# the wall when you lean/walk into one, and you get stuck. Instead: sweep it toward the
# head, and if a wall blocks it, push the whole rig back out so the head stays outside.
func update_body_collision() -> void:
	var target := head.global_position - BODY_OFFSET
	var col := KinematicCollision3D.new()

	# safety net: already overlapping something -> depenetrate the rig
	if player.test_move(player.global_transform, Vector3.ZERO, col, 0.001, true):
		player.global_position += col.get_normal() * (col.get_depth() + 0.002)
		target = head.global_position - BODY_OFFSET

	var motion := target - player_collision.global_position
	if motion.length_squared() > 0.0000001 and player.test_move(player.global_transform, motion, col, 0.001, false):
		var rest := col.get_remainder()
		var n := col.get_normal()
		var push := n * maxf(0.0, -rest.dot(n))
		player.global_position += push
		# capsule is a child of the rig, so it already moved by push
		player_collision.global_position += col.get_travel()
	else:
		player_collision.global_position = head.global_position - BODY_OFFSET

func init() -> void:
	prev_left = left_hand.global_position
	prev_right = right_hand.global_position
	left_hand_follower.global_position = prev_left
	right_hand_follower.global_position = prev_right
	for i in range(velocity_history_size):
		velocity_history.append(Vector3.ZERO)
	previous_position = player.global_position

func set_turn(mode:String, speed:int) -> void:
	turn_mode = mode
	turn_speed = clampi(speed, 1, 9)

func _update_turn(delta:float) -> void:
	if turn_mode == "NONE" or right_ctrl == null or not right_ctrl.get_is_active():
		return
	var x := right_ctrl.get_vector2("primary").x
	var angle := 0.0
	if turn_mode == "SNAP":
		if absf(x) < 0.4:
			_snap_ready = true
		elif _snap_ready and absf(x) > 0.7:
			_snap_ready = false
			angle = -signf(x) * deg_to_rad(turn_speed * 10.0)
	elif absf(x) > 0.2:
		angle = -x * deg_to_rad(turn_speed * 20.0) * delta
	if angle != 0.0:
		_rotate_about_head(angle)

# Turns the tracking space around your head so you stay put and the world swings round.
func _rotate_about_head(angle:float) -> void:
	var pivot := head.global_position
	var rel := (xr_origin.global_position - pivot).rotated(Vector3.UP, angle)
	xr_origin.global_position = pivot + rel
	xr_origin.rotate_y(angle)
	prev_left = left_hand.global_position # the turn is not arm movement
	prev_right = right_hand.global_position

# Move the whole rig (used for spawning / respawning).
func teleport_to(pos:Vector3) -> void:
	player.global_position = pos
	player.velocity = Vector3.ZERO
	is_moving = false
	velocity_average = Vector3.ZERO
	for i in velocity_history.size():
		velocity_history[i] = Vector3.ZERO
	previous_position = player.global_position
	prev_left = left_hand.global_position
	prev_right = right_hand.global_position
	left_hand_follower.global_position = prev_left
	right_hand_follower.global_position = prev_right

func store_velocities(delta:float) -> void:
	if delta <= 0.0:
		return
	velocity_index = (velocity_index + 1) % velocity_history_size
	var oldest_velocity := velocity_history[velocity_index]
	var current_velocity := (player.global_position - previous_position) / delta
	velocity_average += (current_velocity - oldest_velocity) / float(velocity_history_size);
	velocity_history[velocity_index] = current_velocity
	previous_position = player.global_position

# The pose sent to the other players in your room, world space (layout documented in remote_player.gd):
# head position + rotation, both controller rotations, and where both gorilla hands are drawn.
func get_net_pose() -> PackedFloat32Array:
	var left_ctrl:Node3D = $Player/XROrigin3D/LeftHand
	var hp := head.global_position
	var hq := head.global_basis.orthonormalized().get_rotation_quaternion()
	var lq := left_ctrl.global_basis.orthonormalized().get_rotation_quaternion()
	var rq := right_ctrl.global_basis.orthonormalized().get_rotation_quaternion()
	var lp := left_hand_follower.global_position
	var rp := right_hand_follower.global_position
	return PackedFloat32Array([
		hp.x, hp.y, hp.z, hq.x, hq.y, hq.z, hq.w,
		lq.x, lq.y, lq.z, lq.w, rq.x, rq.y, rq.z, rq.w,
		lp.x, lp.y, lp.z, rp.x, rp.y, rp.z])
