extends Node3D
# Loads the Gorilla Tag map (Map/source/GorillaTagMap.fbx), generates collision for every
# mesh so you can climb / push off all of it, drops the FBX's own lights & cameras, and
# respawns the player if they fall out of the world.

const StumpMirror := preload("res://Scripts/stump_mirror.gd")
const CosmeticsRoom := preload("res://Scripts/cosmetics.gd")
const GorillaComputer := preload("res://Scripts/gorilla_computer.gd")
const CaveMusic := preload("res://Scripts/cave_music.gd")
const SkyWeather := preload("res://Scripts/sky_weather.gd")

@export var enable_day_night:bool = true # the sky glides through morning, noon, evening and night
@export var day_length_seconds:float = 600.0 # real seconds for one full 24 h day
@export_range(0.0, 24.0, 0.1) var start_hour:float = 10.0 # time of day at launch (12 = noon, 0 = midnight)
@export var enable_rain:bool = true # now and then it rains in the forest (F8 = toggle rain, F9 = +1 hour, on desktop)
@export_range(0.0, 1.0, 0.01) var cave_light_level:float = 0.02 # sun/moon/ambient light that reaches inside the caves (1 = unchanged, 0 = pitch black except lamps and crystals)
@export_range(0.0, 1.0, 0.01) var mines_light_level:float = 0.08 # same, but inside the mines (below the crystal room): a bit brighter than the other caves
@export var rain_everywhere:bool = false # true = rain falls on the whole map, not just the forest

@export var enable_mirror:bool = true # the working mirror in the Stump's top room
@export var enable_cosmetics:bool = true # touch a hat-room button to wear that item
@export_range(0.0, 1.0, 0.01) var cave_brightness:float = 0.02 # caves + mines: 1.0 = unchanged, lower = darker (crystals and lamps are not dimmed)
@export_range(0.0, 1.0, 0.01) var mines_brightness:float = 0.2 # the mines (below the crystal room) are brighter than the other caves: same scale as cave_brightness
@export_range(0.0, 1.0, 0.05) var cave_lamp_level:float = 0.2 # brightness of the lamps inside the caves and mines: 1.0 = unchanged (outdoor lighting and crystals are not touched)
@export_range(0.0, 6.0, 0.1) var crystal_glow_energy:float = 2.5 # how strongly the crystals glow (0 = no glow)
@export var enable_cave_music:bool = true # plays Map/audio/cave_wave.ogg (.mp3 / .wav) while you are inside the caves
@export var map_scene:PackedScene = preload("res://Map/source/GorillaTagMap.fbx")
@export var spawn_position:Vector3 = Vector3(5.8, 10.04, -12.0) # where the player starts / respawns: inside the Stump (tree room), on the floor in front of the Gorilla Computer
@export var kill_y:float = -90.0 # fall below this height -> respawn
@export var skip_collision_prefixes:PackedStringArray = ["Light", "cavemonitor"]
# Foliage you should be able to reach through to grab the branch behind it (lower-case prefixes / material names).
@export var no_collision_prefixes:PackedStringArray = ["smallleaves", "bush"]
@export var no_collision_materials:PackedStringArray = ["leaves", "bush", "bush2"]
# true  = a surface only blocks you from the side you can SEE it from (back-face culled faces are
#         invisible AND passable), which removes invisible barriers.
# false = every face blocks from both sides (old behaviour).
@export var match_collision_to_visuals:bool = true
# Parts of the map to delete (look + collision). Each entry is a node path ending, matched on whole
# path segments, relative to the map.
#   "tree_fixed/ramp" = the bark ramp spiralling up the Stump tree
#   "ramp_fixed"      = the wooden ramp (and its support posts) beside the Stump
# Another wooden ramp (further left and higher up) is "ramp__1__fixed" -- add it here to remove it too.
@export var remove_parts:PackedStringArray = ["tree_fixed/ramp", "ramp_fixed"]

var _shape_cache := {}
var _player_container:Node3D
var _sky_weather:Node

func _ready() -> void:
	var map := map_scene.instantiate()
	add_child(map)
	_remove_parts(map)
	_prepare(map)
	_darken_caves(map)
	_player_container = get_parent().get_node_or_null("player_container")
	_setup_sky(map)
	_setup_stump(map)
	var computer := GorillaComputer.new()
	computer.name = "GorillaComputerFix"
	add_child(computer)
	computer.setup(map, _player_container, _player_container.get_node_or_null("GorillaBody") if _player_container else null)
	if enable_cave_music and _player_container != null:
		var music := CaveMusic.new()
		music.name = "CaveMusic"
		add_child(music)
		music.setup(map, _player_container.get_node_or_null("Player/XROrigin3D/Head") as Node3D)
	respawn()

# Moving sun / moon / sky and the occasional forest rain (see sky_weather.gd).
func _setup_sky(map:Node) -> void:
	if not (enable_day_night or enable_rain):
		return
	var lighting := get_parent().get_node_or_null("Lighting")
	if lighting == null:
		return
	var sun := lighting.get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	var we := lighting.get_node_or_null("WorldEnvironment") as WorldEnvironment
	var head:Node3D = null
	if _player_container != null:
		head = _player_container.get_node_or_null("Player/XROrigin3D/Head") as Node3D
	var sky := SkyWeather.new()
	sky.name = "SkyWeather"
	sky.day_length_seconds = day_length_seconds if enable_day_night else 0.0
	sky.start_hour = start_hour if enable_day_night else 12.0
	sky.rain_enabled = enable_rain
	sky.rain_everywhere = rain_everywhere
	sky.cave_light_level = cave_light_level
	sky.mines_light_level = mines_light_level
	add_child(sky)
	sky.setup(map, head, sun, we)
	_sky_weather = sky

# Mirror + cosmetics in the Stump's top room.
func _setup_stump(map:Node) -> void:
	if _player_container == null:
		return
	# the room's centre (average of the cosmetic buttons) tells the mirror which side is its front
	var hint := global_position
	var cos_root := map.find_child("Cosmetics", true, false)
	if cos_root != null:
		var sum := Vector3.ZERO
		var n := 0
		for c in cos_root.get_children():
			if c is Node3D:
				sum += (c as Node3D).global_position
				n += 1
		if n > 0:
			hint = sum / n
	var body := _player_container.get_node_or_null("GorillaBody")
	var head := _player_container.get_node_or_null("Player/XROrigin3D/Head") as Node3D
	if enable_cosmetics and body != null:
		var room := CosmeticsRoom.new()
		room.name = "CosmeticsRoom"
		add_child(room)
		room.setup(map, _player_container, body, hint)
	if enable_mirror and head != null:
		var env:Environment = null
		var we := get_parent().get_node_or_null("Lighting/WorldEnvironment") as WorldEnvironment
		if we != null and we.environment != null:
			# the mirror picture is tonemapped once, by your own camera, not twice
			env = we.environment.duplicate() as Environment
			env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
			env.glow_enabled = false
			if _sky_weather != null:
				_sky_weather.register_environment(env) # so the mirror shows the same time of day / weather
		var mirror := StumpMirror.new()
		mirror.name = "StumpMirror"
		add_child(mirror)
		mirror.setup(map, head, hint, env)

func _remove_parts(root:Node) -> void:
	var doomed:Array[Node] = []
	_collect_parts(root, root, doomed)
	for n in doomed:
		n.get_parent().remove_child(n)
		n.queue_free()
	if doomed.size() < remove_parts.size():
		push_warning("GTagMap: only removed %d of %d requested parts -- check remove_parts" % [doomed.size(), remove_parts.size()])

func _collect_parts(root:Node, node:Node, out:Array[Node]) -> void:
	for child in node.get_children():
		var path := str(root.get_path_to(child))
		var hit := false
		for part in remove_parts:
			if path == part or path.ends_with("/" + part):
				hit = true
				break
		if hit:
			out.append(child) # the whole subtree goes, no need to look inside
		else:
			_collect_parts(root, child, out)

func _prepare(node:Node) -> void:
	for child in node.get_children():
		# the FBX ships its own (huge-scaled) lights and cameras; the scene has its own lighting
		if child is Light3D or child is Camera3D:
			child.queue_free()
			continue
		_prepare(child)
	if node is MeshInstance3D and node.mesh != null:
		_fix_materials(node)
		_add_collision(node)

# Hidden nodes, foliage and surfaces whose material is see-through get no collision, so nothing
# invisible blocks your hands.
func _add_collision(node:MeshInstance3D) -> void:
	if not node.is_visible_in_tree():
		return
	var par := node.get_parent()
	if par != null and (String(par.name) == "Cosmetics" or String(par.name) == "Keys"):
		return # buttons are touched, not bumped into
	var node_name := String(node.name)
	for p in skip_collision_prefixes:
		if node_name.begins_with(p):
			return
	var lname := node_name.to_lower()
	for p in no_collision_prefixes:
		if lname.begins_with(p):
			return
	var mesh:Mesh = node.mesh
	if not _shape_cache.has(mesh):
		_shape_cache[mesh] = _make_shapes(mesh)
	var shapes:Array = _shape_cache[mesh]
	if shapes.is_empty():
		return
	var body := StaticBody3D.new()
	body.name = "Collision"
	for shape in shapes:
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
	node.add_child(body)

func respawn() -> void:
	if _player_container and _player_container.has_method("teleport_to"):
		_player_container.teleport_to(spawn_position)

func _physics_process(_delta:float) -> void:
	if _player_container == null:
		return
	var player := _player_container.get_node_or_null("Player") as Node3D
	if player and player.global_position.y < kill_y:
		respawn()

# Builds the collision shape(s) for a mesh, surface by surface:
#  - surfaces with foliage / see-through materials are left out
#  - a surface is two-sided only if its material is drawn two-sided (cull_mode disabled), so you
#    can't be blocked by a face you cannot see
func _make_shapes(mesh:Mesh) -> Array:
	var groups := {true: [], false: []} # two_sided -> [surface indices]
	var surface_count := mesh.get_surface_count()
	for i in surface_count:
		var two_sided := true
		var m := mesh.surface_get_material(i) as BaseMaterial3D
		if m != null:
			if no_collision_materials.has(_base_name(m.resource_name)) or _is_see_through(m):
				continue
			if match_collision_to_visuals:
				two_sided = m.cull_mode == BaseMaterial3D.CULL_DISABLED
		groups[two_sided].append(i)
	var shapes := []
	for two_sided in [true, false]:
		var surfaces:Array = groups[two_sided]
		if surfaces.is_empty():
			continue
		var shape:ConcavePolygonShape3D
		if surfaces.size() == surface_count:
			shape = mesh.create_trimesh_shape() as ConcavePolygonShape3D # fast native path
		else:
			var faces := PackedVector3Array()
			for i in surfaces:
				faces.append_array(_surface_faces(mesh, i))
			if faces.is_empty():
				continue
			shape = ConcavePolygonShape3D.new()
			shape.set_faces(faces)
		if shape == null:
			continue
		shape.backface_collision = two_sided
		shapes.append(shape)
	return shapes

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

# The importer marks some materials transparent; if nothing visible is left of one it is a ghost.
func _is_see_through(m:BaseMaterial3D) -> bool:
	return m.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED and m.albedo_texture == null and m.albedo_color.a < 0.05

# The FBX lost some textures (they were not in the export), so those surfaces came out plain
# white. Give them sensible colours by material name.
const FALLBACK_COLORS := {
	"canyon5": Color(0.72, 0.42, 0.28),
	"rusty": Color(0.55, 0.3, 0.18),
	"shelfwood": Color(0.6, 0.42, 0.25),
	"crate": Color(0.62, 0.43, 0.22),
	"table": Color(0.5, 0.33, 0.2),
	"carttexture": Color(0.42, 0.28, 0.2),
	"riverwall": Color(0.35, 0.38, 0.42),
	"riverbed": Color(0.45, 0.4, 0.33),
	"minewall": Color(0.4, 0.3, 0.2),
	"woodensupport": Color(0.45, 0.3, 0.18),
	"hatboard": Color(0.4, 0.28, 0.18),
	"plastic": Color(0.18, 0.18, 0.2),
	"keyboard": Color(0.2, 0.2, 0.22),
	"knobs": Color(0.7, 0.7, 0.72),
	"sunhat": Color(0.62, 0.82, 0.95),
	"tophatfabric": Color(0.07, 0.07, 0.08),
	"redhat": Color(0.75, 0.1, 0.1),
	"cowboyhat": Color(0.5, 0.33, 0.18),
	"fez": Color(0.7, 0.1, 0.1),
	"coconutinside": Color(0.95, 0.93, 0.85),
	"coconut": Color(0.38, 0.24, 0.14),
	"sunglassesf": Color(0.08, 0.08, 0.1),
	"earlyaccess": Color(0.95, 0.75, 0.2),
	"headmodel": Color(0.75, 0.75, 0.78),
	"mirror": Color(0.75, 0.85, 0.9),
}
# Hat materials get a matte cloth/straw finish (the importer made them glossy).
const HAT_MATERIALS := ["tophatfabric", "redhat", "cowboyhat", "fez", "sunhat", "coconut", "coconutinside", "sunglassesf", "earlyaccess"]
# The hat textures were not in the export. If you add them (fez.png, cowboyhat.png, ...) to one of these
# folders they are picked up automatically.
const TEXTURE_DIRS := ["res://Map/textures", "res://Map/hats"]
const GLOW_COLORS := {
	"screen": Color(0.08, 0.55, 0.25), # every board / monitor face is green
	"light": Color(1.0, 0.85, 0.5),
	"crystallrteal": Color(0.3, 0.9, 0.95),
	"crystallrpink": Color(1.0, 0.55, 0.85),
	"crystallrpurple": Color(0.7, 0.5, 1.0),
	"crystallryellow": Color(1.0, 0.9, 0.35),
}
# Crystal materials (all four colours). The purple ones in the crystal rooms use a texture, so they glow through it.
const CRYSTAL_KEYS := ["crystallrteal", "crystallrpink", "crystallrpurple", "crystallryellow"]
const CRYSTAL_TEXTURED_TINT := Color(0.85, 0.65, 1.0)

func _base_name(n:String) -> String:
	var dot := n.rfind(".")
	if dot > 0 and n.substr(dot + 1).is_valid_int():
		n = n.substr(0, dot)
	return n.to_lower()

var _fixed_materials := {}
var _dark_materials := {}
var _dark_materials_mines := {}

# Caves and mines (everything inside the map's "Cave_fixed" group) get darker walls, floors and props.
# Each surface gets its own darker copy of the material as an override, so the same material used
# outside the caves is left alone. Crystals, lamps and screens (anything glowing) are not dimmed.
func _darken_caves(map:Node) -> void:
	if cave_brightness >= 0.999:
		return
	var cave := map.find_child("Cave_fixed", true, false)
	if cave == null:
		push_warning("GTagMap: no 'Cave_fixed' node in the map, so the caves were not darkened")
		return
	var meshes:Array = []
	if cave is MeshInstance3D:
		meshes.append(cave)
	meshes.append_array(cave.find_children("*", "MeshInstance3D", true, false))
	var tint := Color(cave_brightness, cave_brightness, cave_brightness, 1.0)
	var mines_tint := Color(mines_brightness, mines_brightness, mines_brightness, 1.0)
	var mines := cave.find_child("Mines_fixed", true, false)
	for mi in meshes:
		var mesh_node := mi as MeshInstance3D
		if mesh_node.mesh == null:
			continue
		var lname := String(mesh_node.name).to_lower()
		if lname.begins_with("crystal") or lname.begins_with("light") or lname.begins_with("cavemonitor"):
			continue
		var in_mines := mines != null and (mines == mesh_node or mines.is_ancestor_of(mesh_node))
		var cache := _dark_materials_mines if in_mines else _dark_materials
		var use_tint := mines_tint if in_mines else tint
		for i in mesh_node.mesh.get_surface_count():
			var m := mesh_node.mesh.surface_get_material(i) as BaseMaterial3D
			if m == null or m.emission_enabled:
				continue
			if not cache.has(m):
				var d := m.duplicate() as BaseMaterial3D
				d.albedo_color = m.albedo_color * use_tint
				cache[m] = d
			mesh_node.set_surface_override_material(i, cache[m])

func _fix_materials(mi:MeshInstance3D) -> void:
	var mesh := mi.mesh
	for i in mesh.get_surface_count():
		var m := mesh.surface_get_material(i) as BaseMaterial3D
		if m == null or _fixed_materials.has(m):
			continue
		_fixed_materials[m] = true
		var key := _base_name(m.resource_name)
		if m.albedo_texture != null:
			# opaque textures that the importer flagged transparent render as ghosts
			m.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			if CRYSTAL_KEYS.has(key) and crystal_glow_energy > 0.0:
				m.emission_enabled = true
				m.emission_texture = m.albedo_texture
				m.emission = CRYSTAL_TEXTURED_TINT
				m.emission_energy_multiplier = crystal_glow_energy
			continue
		if key == "glass":
			# sunglasses lens: keep the tint from the map, but see-through
			m.albedo_color = Color(m.albedo_color.r, m.albedo_color.g, m.albedo_color.b, 0.7)
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.roughness = 0.15
			continue
		if _texture_override(m, key):
			continue
		if key == "earlyaccess":
			var sm := _early_access_material(mesh, i)
			if sm != null:
				mesh.surface_set_material(i, sm)
			continue
		if GLOW_COLORS.has(key):
			var c:Color = GLOW_COLORS[key]
			m.albedo_color = c
			m.emission_enabled = true
			m.emission = c
			if CRYSTAL_KEYS.has(key):
				m.emission_energy_multiplier = crystal_glow_energy
			elif key == "light":
				m.emission_energy_multiplier = 0.6 * cave_lamp_level # the cave lamps
			else:
				m.emission_energy_multiplier = 0.6
		elif FALLBACK_COLORS.has(key):
			m.albedo_color = FALLBACK_COLORS[key]
		if HAT_MATERIALS.has(key):
			m.roughness = 0.85
			m.metallic = 0.0

# Uses a real texture for a material if one was added to Map/textures or Map/hats (key.png).
func _texture_override(m:BaseMaterial3D, key:String) -> bool:
	for dir in TEXTURE_DIRS:
		var p := "%s/%s.png" % [dir, key]
		if ResourceLoader.exists(p):
			var t := load(p) as Texture2D
			if t != null:
				m.albedo_texture = t
				m.albedo_color = Color.WHITE
				return true
	return false

# Early Access badge: a black plate with the raised emblem in green. The raised part is the side of the
# thin axis that has the dense little triangles; colour is picked per pixel from how far out it sticks.
const EA_SHADER := """
shader_type spatial;
uniform int axis = 1;
uniform float thr = 0.0;
uniform float dir = -1.0;
varying float depth;
void vertex() {
	depth = axis == 0 ? VERTEX.x : (axis == 1 ? VERTEX.y : VERTEX.z);
}
void fragment() {
	float g = step(0.0, (depth - thr) * dir);
	ALBEDO = mix(vec3(0.02), vec3(0.1, 0.85, 0.25), g);
	ROUGHNESS = 0.55;
}
"""

func _early_access_material(mesh:Mesh, surf:int) -> ShaderMaterial:
	var aabb := mesh.get_aabb()
	var ax := 0
	for a in 3:
		if aabb.size[a] < aabb.size[ax]:
			ax = a
	var arrays := mesh.surface_get_arrays(surf)
	var verts:PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var lo := aabb.position[ax]
	var size := aabb.size[ax]
	if size <= 0.0:
		return null
	var n_lo := 0
	var n_hi := 0
	for v in verts:
		var t := (v[ax] - lo) / size
		if t < 0.35:
			n_lo += 1
		elif t > 0.65:
			n_hi += 1
	var sm := ShaderMaterial.new()
	sm.resource_name = "EarlyAccess"
	var shader := Shader.new()
	shader.code = EA_SHADER
	sm.shader = shader
	sm.set_shader_parameter("axis", ax)
	if n_lo >= n_hi:
		sm.set_shader_parameter("thr", lo + 0.34 * size)
		sm.set_shader_parameter("dir", -1.0)
	else:
		sm.set_shader_parameter("thr", lo + 0.66 * size)
		sm.set_shader_parameter("dir", 1.0)
	return sm
