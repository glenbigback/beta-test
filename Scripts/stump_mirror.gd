extends Node3D
# A real, working mirror for the Stump's top room (the "mirror_fixed/board_2" panel in the map).
#
# Why it was broken: in the original Unity map the mirror's picture is a RenderTexture, and render
# textures can't be exported in an FBX, so the panel imported as a flat blue-white board.
#
# How this works (a planar reflection):
#   - the mirror face is found from the mesh itself (its plane, size and which side is the front),
#   - every frame a hidden camera is placed where your head would be *behind* the mirror (your head
#     reflected through the mirror plane) and looks out through the mirror rectangle,
#   - what that camera sees is shown on the mirror face, so it moves correctly when you move your head,
#   - it only renders while you are near it and looking toward it, so it costs nothing elsewhere.
# You see yourself WITH a head and with the cosmetics you equipped (see gorilla_body.gd, which keeps a
# second copy of the gorilla that only the mirror can see).

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2D mirror_tex : source_color, filter_linear;
uniform vec3 foot = vec3(0.0);
uniform vec3 cam_right = vec3(1.0, 0.0, 0.0);
uniform vec3 cam_up = vec3(0.0, 1.0, 0.0);
uniform vec2 rect_min = vec2(0.0);
uniform vec2 rect_size = vec2(1.0);
uniform float brightness = 1.0;
varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 d = wpos - foot;
	vec2 uv = (vec2(dot(d, cam_right), dot(d, cam_up)) - rect_min) / rect_size;
	uv.y = 1.0 - uv.y;
	ALBEDO = texture(mirror_tex, clamp(uv, vec2(0.0), vec2(1.0))).rgb * brightness;
}
"""

# Visual layers (must match gorilla_body.gd): the mirror camera sees the world (layer 1) and the
# mirror's copy of you (layer 2), but not your first-person body (layer 3).
const LAYER_OWN_BODY := 4

@export var texture_height:int = 512 # pixels; lower = faster on Quest, higher = sharper
@export var max_distance:float = 12.0 # metres; the mirror stops rendering beyond this
@export var brightness:float = 1.0

var _head:Node3D
var _viewport:SubViewport
var _cam:Camera3D
var _mat:ShaderMaterial
var _ok := false
var _active := false
var _origin := Vector3.ZERO # centre of the mirror face
var _n := Vector3.FORWARD # front normal (points into the room)
var _u := Vector3.UP # "up" inside the mirror plane
var _cam_right := Vector3.RIGHT # the hidden camera's right vector
var _a_min := 0.0
var _a_max := 1.0
var _b_min := 0.0
var _b_max := 1.0

func setup(map:Node, head:Node3D, front_hint:Vector3, env:Environment = null) -> bool:
	_head = head
	var holder := map.find_child("mirror_fixed", true, false)
	if holder == null:
		push_warning("StumpMirror: 'mirror_fixed' not found in the map")
		return false
	var board := holder.find_child("board_2", true, false) as MeshInstance3D
	if board == null or board.mesh == null:
		push_warning("StumpMirror: 'board_2' (the mirror panel) not found")
		return false
	var mesh:Mesh = board.mesh
	var surf := -1
	for i in mesh.get_surface_count():
		var m := mesh.surface_get_material(i)
		if m != null and m.resource_name.to_lower().begins_with("mirror"):
			surf = i
			break
	if surf < 0:
		push_warning("StumpMirror: no 'Mirror' surface on the panel")
		return false

	# --- the mirror face: plane, centre, which way is front ---
	var xf := board.global_transform
	var tris := _surface_faces(mesh, surf)
	if tris.size() < 3:
		return false
	var nsum := Vector3.ZERO
	var csum := Vector3.ZERO
	var asum := 0.0
	var pts := PackedVector3Array()
	for k in range(0, tris.size() - 2, 3):
		var a := xf * tris[k]
		var b := xf * tris[k + 1]
		var c := xf * tris[k + 2]
		var cr := (b - a).cross(c - a)
		var area := cr.length() * 0.5
		nsum += cr * 0.5
		csum += (a + b + c) / 3.0 * area
		asum += area
		pts.append(a)
		pts.append(b)
		pts.append(c)
	if asum < 0.000001 or nsum.length() < 0.000001:
		return false
	_origin = csum / asum
	_n = nsum.normalized()
	# the front is the side that faces the cosmetics room, whatever the mesh winding says
	if _n.dot(front_hint - _origin) < 0.0:
		_n = -_n
	_u = (Vector3.UP - _n * _n.dot(Vector3.UP)).normalized()
	_cam_right = _n.cross(_u).normalized()
	_a_min = INF
	_a_max = -INF
	_b_min = INF
	_b_max = -INF
	for p in pts:
		var rel:Vector3 = p - _origin
		var ra := rel.dot(_cam_right)
		var rb := rel.dot(_u)
		_a_min = minf(_a_min, ra)
		_a_max = maxf(_a_max, ra)
		_b_min = minf(_b_min, rb)
		_b_max = maxf(_b_max, rb)
	var w := _a_max - _a_min
	var h := _b_max - _b_min
	if w < 0.001 or h < 0.001:
		return false

	# --- hidden camera + the picture it renders ---
	_viewport = SubViewport.new()
	_viewport.name = "MirrorViewport"
	_viewport.size = Vector2i(maxi(64, roundi(texture_height * w / h)), texture_height)
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_viewport.audio_listener_enable_3d = false
	add_child(_viewport)

	_cam = Camera3D.new()
	_cam.name = "MirrorCamera"
	_cam.projection = Camera3D.PROJECTION_FRUSTUM
	_cam.keep_aspect = Camera3D.KEEP_WIDTH
	_cam.far = 400.0
	_cam.cull_mask = 0xFFFFF & ~LAYER_OWN_BODY
	if env != null:
		_cam.environment = env
	_viewport.add_child(_cam)
	_cam.current = true

	var shader := Shader.new()
	shader.code = SHADER_CODE
	_mat = ShaderMaterial.new()
	_mat.resource_name = "MirrorPicture"
	_mat.shader = shader
	_mat.set_shader_parameter("mirror_tex", _viewport.get_texture())
	_mat.set_shader_parameter("brightness", brightness)
	board.set_surface_override_material(surf, _mat)

	_ok = true
	return true

func _process(_delta:float) -> void:
	if not _ok or _head == null:
		return
	var eye := _head.global_position
	var d := (eye - _origin).dot(_n) # how far in front of the mirror you are
	var look := -_head.global_basis.z
	var want := d > 0.12 and eye.distance_to(_origin) < max_distance and look.dot((_origin - eye).normalized()) > 0.1
	if want != _active:
		_active = want
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if want else SubViewport.UPDATE_DISABLED
	if not want:
		return

	# Your head reflected through the mirror plane; the camera looks out of the mirror into the room.
	var foot := eye - _n * d
	var reflected := eye - _n * (2.0 * d)
	# the near plane is the mirror plane (plus 4 mm), so nothing behind the mirror is drawn
	var near := d + 0.004
	var s := near / d
	var fa := (foot - _origin).dot(_cam_right)
	var fb := (foot - _origin).dot(_u)
	var l := _a_min - fa
	var r := _a_max - fa
	var bt := _b_min - fb
	var tp := _b_max - fb
	_cam.global_transform = Transform3D(Basis(_cam_right, _u, -_n), reflected)
	_cam.near = near
	_cam.size = (r - l) * s
	_cam.frustum_offset = Vector2((l + r) * 0.5 * s, (bt + tp) * 0.5 * s)
	_mat.set_shader_parameter("foot", foot)
	_mat.set_shader_parameter("cam_right", _cam_right)
	_mat.set_shader_parameter("cam_up", _u)
	_mat.set_shader_parameter("rect_min", Vector2(l, bt))
	_mat.set_shader_parameter("rect_size", Vector2(r - l, tp - bt))

# Triangle corner positions (mesh space) of one surface, three per triangle.
func _surface_faces(mesh:Mesh, surface:int) -> PackedVector3Array:
	if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
		return PackedVector3Array()
	var arrays := mesh.surface_get_arrays(surface)
	var verts:PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx = arrays[Mesh.ARRAY_INDEX]
	if idx == null or idx.is_empty():
		return verts
	var faces := PackedVector3Array()
	faces.resize(idx.size())
	for i in idx.size():
		faces[i] = verts[idx[i]]
	return faces
