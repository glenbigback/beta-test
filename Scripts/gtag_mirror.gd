extends Node3D
# Working mirror for the board at the top of the stump (FBX: upper_level_fixed/mirror_fixed/board_2).
#
# The FBX only had a Unity RenderTexture ("Mirror.renderTexture") plus a camera for it, neither of
# which Godot can import, so the glass came out as a flat coloured panel. This rebuilds the mirror:
#   - a SubViewport with a camera placed where your eyes would be if you stood BEHIND the glass
#     (your head reflected through the glass plane), looking through the glass rectangle with an
#     off-axis frustum, so the picture lines up exactly with the frame;
#   - the picture is painted back onto the glass surface with a small unshaded shader.
# The camera sees the "mirror copy" of your body (visible head + your hats/glasses) but not your real
# body, see gorilla_body.gd. It only renders while you are near and in front of the glass.

const BODY_LAYER := 1 << 10 # your real body (hidden from this camera)

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2D mirror_tex : source_color, filter_linear, repeat_disable;
uniform vec3 plane_center;
uniform vec3 axis_x;
uniform vec3 axis_y;
uniform vec2 half_size;
uniform float brightness = 1.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 d = world_pos - plane_center;
	vec2 uv = vec2(0.5 + dot(d, axis_x) / (2.0 * half_size.x), 0.5 - dot(d, axis_y) / (2.0 * half_size.y));
	ALBEDO = texture(mirror_tex, uv).rgb * brightness;
}
"""

@export var resolution_height:int = 768 # pixels tall; the width follows the glass shape
@export var active_distance:float = 12.0 # the mirror only renders when your head is this close (metres)
@export var brightness:float = 1.0

var _board:MeshInstance3D
var _surface := -1
var _viewport:SubViewport
var _camera:Camera3D
var _material:ShaderMaterial
var _head:Camera3D
var _center := Vector3.ZERO
var _normal := Vector3.FORWARD # points out of the glass, towards the room
var _up := Vector3.UP # "up" along the glass
var _half := Vector2(0.2, 0.35) # half width / half height of the glass in metres
var _ok := false

# map: the instanced Gorilla Tag map. room_point: somewhere in the hat room (picks the glass's front).
func setup(map:Node, head_cam:Camera3D, room_point:Vector3, has_room_point:bool) -> void:
	_head = head_cam
	_board = _find_board(map)
	if _board == null or _board.mesh == null:
		push_warning("GTagMirror: mirror board (mirror_fixed/board_2) not found")
		return
	_surface = _find_glass_surface(_board.mesh)
	if _surface < 0:
		push_warning("GTagMirror: no glass surface found on the mirror board")
		return
	if not _measure_glass(room_point, has_room_point):
		push_warning("GTagMirror: could not measure the glass")
		return
	_build_viewport()
	_build_material()
	_ok = true

func _find_board(map:Node) -> MeshInstance3D:
	for n in map.find_children("board_2", "MeshInstance3D", true, false):
		var p := n.get_parent()
		if p != null and String(p.name) == "mirror_fixed":
			return n as MeshInstance3D
	return null

# The surface using the "Mirror" material (the other one is the wooden frame).
func _find_glass_surface(mesh:Mesh) -> int:
	var count := mesh.get_surface_count()
	for i in count:
		var m := mesh.surface_get_material(i)
		if m != null and m.resource_name.to_lower().contains("mirror"):
			return i
	if count == 2: # material names lost: the glass is the smaller surface
		var a := mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var b := mesh.surface_get_arrays(1)[Mesh.ARRAY_VERTEX] as PackedVector3Array
		return 0 if a.size() < b.size() else 1
	return -1

# Works out where the glass is in the world: its plane, centre, size and which way it faces.
func _measure_glass(room_point:Vector3, has_room_point:bool) -> bool:
	var arrays := _board.mesh.surface_get_arrays(_surface)
	var verts:PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if verts.is_empty():
		return false
	var xf := _board.global_transform
	var world := PackedVector3Array()
	for v in verts:
		world.append(xf * v)

	var idx := PackedInt32Array()
	if arrays[Mesh.ARRAY_INDEX] != null:
		idx = arrays[Mesh.ARRAY_INDEX]
	var use_idx := not idx.is_empty()
	var count := idx.size() if use_idx else verts.size()

	# plane normal: sum of triangle normals (all flipped to agree with the first one)
	var n := Vector3.ZERO
	var ref := Vector3.ZERO
	var t := 0
	while t + 2 < count:
		var ia := idx[t] if use_idx else t
		var ib := idx[t + 1] if use_idx else t + 1
		var ic := idx[t + 2] if use_idx else t + 2
		var cr := (world[ib] - world[ia]).cross(world[ic] - world[ia])
		if cr.length_squared() > 0.000000000001:
			if ref == Vector3.ZERO:
				ref = cr
			if cr.dot(ref) < 0.0:
				cr = -cr
			n += cr
		t += 3
	if n.length_squared() < 0.000000000001:
		return false
	n = n.normalized()

	# axes along the glass
	var up := Vector3.UP - n * n.dot(Vector3.UP)
	if up.length_squared() < 0.000001:
		up = Vector3.FORWARD - n * n.dot(Vector3.FORWARD)
	up = up.normalized()
	var side := up.cross(n).normalized()

	var p0 := world[0]
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in world:
		var d := p - p0
		var a := d.dot(side)
		var b := d.dot(up)
		lo.x = minf(lo.x, a)
		lo.y = minf(lo.y, b)
		hi.x = maxf(hi.x, a)
		hi.y = maxf(hi.y, b)
	_half = (hi - lo) * 0.5
	if _half.x < 0.001 or _half.y < 0.001:
		return false
	_center = p0 + side * ((lo.x + hi.x) * 0.5) + up * ((lo.y + hi.y) * 0.5)
	_up = up

	# the front is the side facing the hat room
	if has_room_point and (room_point - _center).dot(n) < 0.0:
		n = -n
	_normal = n
	return true

func _build_viewport() -> void:
	var aspect := _half.x / _half.y
	var h := maxi(resolution_height, 64)
	var w := maxi(roundi(h * aspect), 64)
	_viewport = SubViewport.new()
	_viewport.name = "MirrorViewport"
	_viewport.size = Vector2i(w, h)
	_viewport.msaa_3d = Viewport.MSAA_2X
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)

	_camera = Camera3D.new()
	_camera.name = "MirrorCamera"
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_camera.cull_mask = 0xFFFFF & ~BODY_LAYER
	_viewport.add_child(_camera)
	_camera.current = true

	# the main view tone-maps the picture again, so render the mirror with a linear tone-map
	var found := get_tree().root.find_children("*", "WorldEnvironment", true, false)
	if not found.is_empty():
		var env := (found[0] as WorldEnvironment).environment
		if env != null:
			var copy := env.duplicate() as Environment
			copy.tonemap_mode = Environment.TONE_MAPPER_LINEAR
			copy.glow_enabled = false
			_camera.environment = copy

func _build_material() -> void:
	var shader := Shader.new()
	shader.code = SHADER_CODE
	_material = ShaderMaterial.new()
	_material.shader = shader
	_material.set_shader_parameter("mirror_tex", _viewport.get_texture())
	_material.set_shader_parameter("plane_center", _center)
	_material.set_shader_parameter("axis_x", _normal.cross(_up))
	_material.set_shader_parameter("axis_y", _up)
	_material.set_shader_parameter("half_size", _half)
	_material.set_shader_parameter("brightness", brightness)
	_board.set_surface_override_material(_surface, _material)

func _process(_delta:float) -> void:
	if not _ok or _head == null or not is_instance_valid(_head):
		return
	var head_pos := _head.global_position
	var to_head := head_pos - _center
	var dist := to_head.dot(_normal) # how far in front of the glass you are
	if dist <= 0.03 or to_head.length() > active_distance:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	# your eye mirrored through the glass; the camera looks out through the glass at the room
	var eye := head_pos - 2.0 * dist * _normal
	var x_axis := _normal.cross(_up)
	var cam_basis := Basis(x_axis, _up, -_normal)
	_camera.global_transform = Transform3D(cam_basis, eye)

	# off-axis frustum through the glass rectangle (near plane just in front of the glass)
	var c := cam_basis.inverse() * (_center - eye)
	var near := dist + 0.02
	var k := near / dist
	_camera.set_frustum(2.0 * _half.y * k, Vector2(c.x * k, c.y * k), near, 200.0)
	_material.set_shader_parameter("axis_x", x_axis)
