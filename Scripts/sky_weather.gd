extends Node
# Day / night cycle + occasional rain.
#
#  * The sun, a moon, the sky colours, the ambient light and the fog all glide through
#    night -> dawn -> morning -> noon -> afternoon -> dusk -> night, one full day every
#    `day_length_seconds`. Nothing ever jumps: every value is blended between hour keyframes.
#  * Every now and then a rain shower rolls in: the sky turns grey, the sun dims, a little fog
#    appears, and while you are in the FOREST you see and hear rain. It fades in and out.
#    Rain does not fall through roofs (the Stump room, bridges...) - you just hear it muffled.
#
# Created by gtag_map.gd. Desktop test keys:  F8 = start / stop rain,  F9 = jump 1 hour ahead.

const HOURS := [0.0, 5.0, 6.0, 7.5, 9.0, 12.0, 15.0, 16.5, 18.0, 19.0, 20.5, 22.0, 24.0]
# (first and last entry of every list must match so midnight wraps without a jump)
const SKY_TOP := [
	Color(0.010, 0.016, 0.050), Color(0.012, 0.020, 0.060), Color(0.20, 0.25, 0.44), Color(0.33, 0.43, 0.62),
	Color(0.37, 0.45, 0.58), Color(0.385, 0.454, 0.55), Color(0.37, 0.45, 0.57), Color(0.34, 0.40, 0.55),
	Color(0.25, 0.24, 0.42), Color(0.12, 0.12, 0.26), Color(0.03, 0.04, 0.10), Color(0.010, 0.016, 0.050),
	Color(0.010, 0.016, 0.050)]
const SKY_HORIZON := [
	Color(0.035, 0.045, 0.090), Color(0.05, 0.06, 0.11), Color(0.95, 0.56, 0.36), Color(0.80, 0.74, 0.70),
	Color(0.68, 0.69, 0.70), Color(0.646, 0.656, 0.671), Color(0.68, 0.68, 0.68), Color(0.82, 0.66, 0.52),
	Color(0.98, 0.48, 0.25), Color(0.55, 0.28, 0.32), Color(0.10, 0.10, 0.18), Color(0.04, 0.05, 0.10),
	Color(0.035, 0.045, 0.090)]
const AMBIENT := [
	Color(0.07, 0.09, 0.17), Color(0.08, 0.10, 0.18), Color(0.36, 0.34, 0.40), Color(0.46, 0.48, 0.54),
	Color(0.50, 0.52, 0.56), Color(0.50, 0.52, 0.56), Color(0.50, 0.52, 0.56), Color(0.48, 0.44, 0.46),
	Color(0.38, 0.30, 0.34), Color(0.20, 0.17, 0.25), Color(0.09, 0.10, 0.18), Color(0.07, 0.09, 0.17),
	Color(0.07, 0.09, 0.17)]
const SUN_COLOR := [
	Color(1.0, 0.55, 0.3), Color(1.0, 0.55, 0.3), Color(1.0, 0.62, 0.38), Color(1.0, 0.88, 0.72),
	Color(1.0, 0.97, 0.92), Color(1.0, 0.98, 0.95), Color(1.0, 0.96, 0.88), Color(1.0, 0.82, 0.60),
	Color(1.0, 0.55, 0.30), Color(1.0, 0.50, 0.30), Color(1.0, 0.50, 0.30), Color(1.0, 0.55, 0.3),
	Color(1.0, 0.55, 0.3)]
const SUN_ENERGY := [0.0, 0.0, 0.3, 0.8, 1.0, 1.0, 1.0, 0.85, 0.3, 0.0, 0.0, 0.0, 0.0]
const MOON_ENERGY := [0.25, 0.22, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.12, 0.22, 0.25, 0.25]
const MOON_COLOR := Color(0.55, 0.65, 1.0)

# Where the sun is at noon (matches the original light in main.tscn) and the direction it travels towards.
const NOON_DIR := Vector3(0.25, 0.866025, -0.433013)
const EAST_DIR := Vector3(0.866025, 0.0, 0.5)

@export var day_length_seconds:float = 600.0 # real seconds for a full 24 h day; 0 = time stands still
@export_range(0.0, 24.0, 0.1) var start_hour:float = 10.0 # 12 = noon, 0 = midnight
@export var rain_enabled:bool = true
@export var first_rain_after:Vector2 = Vector2(1500.0, 2100.0) # seconds until the first shower (min, max)
@export var dry_spell_seconds:Vector2 = Vector2(1500.0, 2100.0) # time between showers (min, max)
@export var rain_spell_seconds:Vector2 = Vector2(60.0, 150.0) # how long a shower lasts (min, max)
@export var rain_fade_seconds:float = 12.0 # how slowly rain starts / stops
@export var rain_everywhere:bool = false # true = rain falls on the whole map, not just the forest
@export var forest_node_name:String = "Forest_fixed" # map node that marks the forest
@export var forest_margin:float = 8.0 # metres the rainy area reaches past the forest's edge
@export var forest_bounds_override:AABB = AABB() # set a non-empty box to define the rainy area by hand
@export var cave_node_name:String = "Cave_fixed" # map node that holds the caves and mines
@export_range(0.0, 1.0, 0.01) var cave_light_level:float = 0.02 # sun / moon / ambient light left inside the caves (1 = no change)
@export var mines_node_name:String = "Mines_fixed" # the mines (below the crystal room)
@export var crystal_room_node_name:String = "crystal_room_fixed"
@export_range(0.0, 1.0, 0.01) var mines_light_level:float = 0.08 # like cave_light_level, but for the mines (a bit brighter)
@export var max_drops:int = 900
@export var rain_volume_db:float = -24.0

var _head:Node3D
var _sun:DirectionalLight3D
var _moon:DirectionalLight3D
var _env:Environment
var _sky_mat:ProceduralSkyMaterial
var _extra_envs:Array = []

var _hour:float = 10.0
var _rain:float = 0.0 # current rain strength 0..1 (eased)
var _rain_target:float = 0.0
var _weather_timer:float = 60.0

var _forest_box:AABB
var _have_forest := false
var _in_zone := false
var _sheltered := false
var _zone_mix := 0.0
var _shelter_mix := 0.0
var _check_timer := 0.0
var _cave:Node
var _cave_box:AABB
var _have_cave := false
var _in_cave := false
var _mines_box:AABB
var _crystal_box:AABB
var _in_mines := false
var _mines_mix := 0.0
var _cave_mix := 0.0

var _rain_root:Node3D
var _drops:GPUParticles3D
var _drop_mat:StandardMaterial3D
var _rain_audio:AudioStreamPlayer

func setup(map:Node, head:Node3D, sun:DirectionalLight3D, world_env:WorldEnvironment) -> void:
	_head = head
	_sun = sun
	_hour = fposmod(start_hour, 24.0)
	if world_env != null and world_env.environment != null:
		_env = world_env.environment
		_sky_mat = (_env.sky.sky_material as ProceduralSkyMaterial) if _env.sky != null else null
	if _sun != null:
		_moon = DirectionalLight3D.new()
		_moon.name = "Moon"
		_moon.shadow_enabled = false
		_moon.light_color = MOON_COLOR
		_sun.get_parent().add_child(_moon)
	_find_forest(map)
	_find_cave(map)
	_weather_timer = randf_range(first_rain_after.x, first_rain_after.y)
	if rain_enabled and _head != null:
		_build_rain()
	_apply()

# Environments that were copied from the main one (the Stump mirror's) so they follow the weather too.
func register_environment(env:Environment) -> void:
	if env != null and not _extra_envs.has(env):
		_extra_envs.append(env)
		_apply()

func set_hour(h:float) -> void:
	_hour = fposmod(h, 24.0)

func set_raining(on:bool) -> void:
	_rain_target = randf_range(0.7, 1.0) if on else 0.0
	_weather_timer = randf_range(rain_spell_seconds.x, rain_spell_seconds.y) if on else randf_range(dry_spell_seconds.x, dry_spell_seconds.y)

func _unhandled_key_input(event:InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if k.keycode == KEY_F8:
		set_raining(_rain_target <= 0.0)
	elif k.keycode == KEY_F9:
		set_hour(_hour + 1.0)

# ---------------------------------------------------------------- forest area

func _find_forest(map:Node) -> void:
	if forest_bounds_override.size.length() > 0.01:
		_forest_box = forest_bounds_override
		_have_forest = true
		return
	var forest:Node = null
	if map != null:
		forest = map.find_child(forest_node_name, true, false)
	if forest == null:
		push_warning("SkyWeather: no '%s' node in the map, so rain falls everywhere outdoors" % forest_node_name)
		return
	var meshes:Array = []
	if forest is MeshInstance3D:
		meshes.append(forest)
	meshes.append_array(forest.find_children("*", "MeshInstance3D", true, false))
	var have := false
	var box := AABB()
	for mi in meshes:
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		var b:AABB = m.global_transform * m.get_aabb()
		box = b if not have else box.merge(b)
		have = true
	if not have:
		return
	box = box.grow(forest_margin)
	box.size.y += 60.0 # open sky above the trees
	_forest_box = box
	_have_forest = true
	print("SkyWeather: rain zone (forest) = ", _forest_box)

func _node_bounds(root:Node) -> AABB:
	var box := AABB()
	if root == null:
		return box
	var have := false
	var meshes:Array = []
	if root is MeshInstance3D:
		meshes.append(root)
	meshes.append_array(root.find_children("*", "MeshInstance3D", true, false))
	for mi in meshes:
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		var b:AABB = m.global_transform * m.get_aabb()
		box = b if not have else box.merge(b)
		have = true
	return box

func _find_cave(map:Node) -> void:
	if map == null:
		return
	_mines_box = _node_bounds(map.find_child(mines_node_name, true, false))
	_crystal_box = _node_bounds(map.find_child(crystal_room_node_name, true, false))
	_cave = map.find_child(cave_node_name, true, false)
	if _cave == null:
		push_warning("SkyWeather: no '%s' node in the map, so the caves are not darkened by the light" % cave_node_name)
		return
	var meshes:Array = []
	if _cave is MeshInstance3D:
		meshes.append(_cave)
	meshes.append_array(_cave.find_children("*", "MeshInstance3D", true, false))
	for mi in meshes:
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		var b:AABB = m.global_transform * m.get_aabb()
		_cave_box = b if not _have_cave else _cave_box.merge(b)
		_have_cave = true

# ---------------------------------------------------------------- per frame

func _process(delta:float) -> void:
	if day_length_seconds > 0.0:
		_hour = fposmod(_hour + delta * 24.0 / day_length_seconds, 24.0)

	# weather state machine: dry spell -> shower -> dry spell ..., strength always eased
	if rain_enabled:
		_weather_timer -= delta
		if _weather_timer <= 0.0:
			set_raining(_rain_target <= 0.0)
	_rain = move_toward(_rain, _rain_target, delta / maxf(rain_fade_seconds, 0.1))

	var want_zone := 1.0 if (_in_zone or rain_everywhere or not _have_forest) else 0.0
	_zone_mix = move_toward(_zone_mix, want_zone, delta / 2.0)
	_shelter_mix = move_toward(_shelter_mix, 1.0 if _sheltered else 0.0, delta / 0.6)
	_cave_mix = move_toward(_cave_mix, 1.0 if _in_cave else 0.0, delta / 0.7)
	_mines_mix = move_toward(_mines_mix, 1.0 if _in_mines else 0.0, delta / 0.7)

	_apply()
	_update_rain_nodes()

func _physics_process(delta:float) -> void:
	_check_timer -= delta
	if _check_timer > 0.0 or _head == null:
		return
	_check_timer = 0.15
	var p := _head.global_position
	_in_zone = (not _have_forest) or _forest_box.has_point(p)
	# anything solid within 20 m straight above your head = you are under a roof
	var space := _head.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(p, p + Vector3.UP * 20.0)
	query.collision_mask = 1 # the map; the player and hands are on layer 2
	var hit := space.intersect_ray(query)
	_sheltered = not hit.is_empty()
	# inside the caves / mines = inside the cave box AND something solid is overhead. (Part of the cave rock
	# belongs to the Forest mesh, so we cannot ask whether the ceiling is "Cave_fixed" specifically.)
	_in_cave = false
	if _have_cave and _cave_box.grow(1.0).has_point(p):
		var cq := PhysicsRayQueryParameters3D.create(p, p + Vector3.UP * 60.0)
		cq.collision_mask = 1
		_in_cave = not space.intersect_ray(cq).is_empty()
	# the mines (but not the crystal room above them) get a bit more light than the other caves
	_in_mines = _in_cave and _mines_box.size.length() > 0.01 and _mines_box.grow(1.0).has_point(p) \
		and not (_crystal_box.size.length() > 0.01 and _crystal_box.grow(0.5).has_point(p))

# ---------------------------------------------------------------- sky + light

func _sample(values:Array, h:float) -> Variant:
	for i in range(HOURS.size() - 1):
		var a:float = HOURS[i]
		var b:float = HOURS[i + 1]
		if h <= b:
			return lerp(values[i], values[i + 1], clampf((h - a) / (b - a), 0.0, 1.0))
	return values[values.size() - 1]

func _overcast(c:Color, w:float, dim:float) -> Color:
	var l := (c.r * 0.30 + c.g * 0.59 + c.b * 0.11) * dim
	return c.lerp(Color(l, l, l * 1.04, 1.0), w * 0.85)

func _apply() -> void:
	var w := smoothstep(0.0, 1.0, _rain) # how overcast / stormy it is
	# the lights have no shadows, so they would shine straight through the rock: turn them down while you are in a cave
	var cave_level := lerpf(cave_light_level, mines_light_level, smoothstep(0.0, 1.0, _mines_mix))
	var cave_k := lerpf(1.0, cave_level, smoothstep(0.0, 1.0, _cave_mix))

	var top := _overcast(_sample(SKY_TOP, _hour), w, 0.65)
	var horizon := _overcast(_sample(SKY_HORIZON, _hour), w, 0.8)
	if _sky_mat != null:
		_sky_mat.sky_top_color = top
		_sky_mat.sky_horizon_color = horizon
		_sky_mat.ground_horizon_color = horizon
		_sky_mat.ground_bottom_color = Color(horizon.r * 0.35, horizon.g * 0.35, horizon.b * 0.35, 1.0)

	# sun / moon: the sun's arc matches the scene's original light at noon; the moon sits opposite it
	var a := (_hour - 12.0) / 12.0 * PI
	var to_sun := (NOON_DIR * cos(a) + EAST_DIR * sin(a)).normalized()
	if _sun != null:
		_sun.global_transform = Transform3D(Basis.looking_at(-to_sun, Vector3.UP), Vector3.ZERO)
		var sun_col:Color = _sample(SUN_COLOR, _hour)
		_sun.light_color = sun_col.lerp(Color(0.85, 0.88, 0.92), w * 0.6)
		var se:float = _sample(SUN_ENERGY, _hour)
		_sun.light_energy = se * (1.0 - 0.7 * w) * cave_k
		_sun.visible = _sun.light_energy > 0.002
	if _moon != null:
		_moon.global_transform = Transform3D(Basis.looking_at(to_sun, Vector3.UP), Vector3.ZERO)
		var me:float = _sample(MOON_ENERGY, _hour)
		_moon.light_energy = me * (1.0 - 0.5 * w) * cave_k
		_moon.visible = _moon.light_energy > 0.002

	var amb := _overcast(_sample(AMBIENT, _hour), w, 0.95)
	var amb_energy := (1.0 - 0.2 * w) * cave_k
	var fog_density := 0.006 * w
	_apply_env(_env, amb, amb_energy, horizon, fog_density)
	for e in _extra_envs:
		_apply_env(e as Environment, amb, amb_energy, horizon, fog_density)

	if _drop_mat != null:
		var lum := amb.r * 0.3 + amb.g * 0.59 + amb.b * 0.11
		var bright := clampf(0.2 + lum * 1.6, 0.2, 1.0)
		_drop_mat.albedo_color = Color(0.78 * bright, 0.85 * bright, 1.0 * bright, 0.38)

func _apply_env(e:Environment, amb:Color, amb_energy:float, fog_color:Color, fog_density:float) -> void:
	if e == null:
		return
	# ambient light is driven directly (not from the sky) so it follows the clock exactly
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = amb
	e.ambient_light_energy = amb_energy
	e.fog_enabled = fog_density > 0.0002
	e.fog_light_color = fog_color
	e.fog_density = fog_density
	e.fog_sky_affect = 0.0

# ---------------------------------------------------------------- rain (drops + sound)

func _build_rain() -> void:
	_rain_root = Node3D.new()
	_rain_root.name = "Rain"
	_rain_root.top_level = true # stays upright and un-rotated while following your head
	add_child(_rain_root)

	var quad := QuadMesh.new()
	quad.size = Vector2(0.012, 0.55)
	_drop_mat = StandardMaterial3D.new()
	_drop_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_drop_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_drop_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_drop_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	_drop_mat.billboard_keep_scale = true
	_drop_mat.albedo_color = Color(0.78, 0.85, 1.0, 0.38)
	quad.material = _drop_mat

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(11.0, 0.1, 11.0)
	pm.direction = Vector3(0.10, -1.0, 0.04) # a little wind
	pm.spread = 1.5
	pm.initial_velocity_min = 14.0
	pm.initial_velocity_max = 18.0
	pm.gravity = Vector3.ZERO
	pm.particle_flag_align_y = true

	_drops = GPUParticles3D.new()
	_drops.name = "Drops"
	_drops.amount = max_drops
	_drops.lifetime = 1.2
	_drops.local_coords = false
	_drops.visibility_aabb = AABB(Vector3(-14, -20, -14), Vector3(28, 30, 28))
	_drops.process_material = pm
	_drops.draw_pass_1 = quad
	_drops.amount_ratio = 0.0
	_drops.emitting = false
	_rain_root.add_child(_drops)

	_rain_audio = AudioStreamPlayer.new()
	_rain_audio.name = "RainSound"
	_rain_audio.stream = _make_rain_loop()
	_rain_audio.volume_db = -80.0
	add_child(_rain_audio)

func _update_rain_nodes() -> void:
	if _rain_root == null or _head == null:
		return
	var seen := _rain * _zone_mix # how much rain is happening where you are
	var drops := seen * (1.0 - _shelter_mix) # drops stop under a roof
	_rain_root.global_position = _head.global_position + Vector3(0.0, 7.0, 0.0)
	_drops.amount_ratio = clampf(drops, 0.0, 1.0)
	_drops.emitting = drops > 0.02

	var heard := seen * (1.0 - 0.8 * _shelter_mix) # indoors it is quieter
	if heard < 0.01:
		if _rain_audio.playing:
			_rain_audio.stop()
	else:
		_rain_audio.volume_db = linear_to_db(pow(heard, 0.7)) + rain_volume_db
		if not _rain_audio.playing:
			_rain_audio.play()

# Two seconds of filtered noise (a soft hiss over a low rumble) that loops without a click.
func _make_rain_loop() -> AudioStreamWAV:
	var rate := 22050
	var n := rate * 2
	var fade := rate / 10
	var total := n + fade
	var x := PackedFloat32Array()
	x.resize(total)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var lp := 0.0
	var lp2 := 0.0
	for i in total:
		var white := rng.randf() * 2.0 - 1.0
		lp += (white - lp) * 0.12
		lp2 += (lp - lp2) * 0.05
		x[i] = (white - lp) * 0.32 + lp2 * 2.6
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		var v:float = x[i]
		if i < fade: # blend the tail into the start so the loop point is seamless
			var t := float(i) / float(fade)
			v = x[i] * t + x[n + i] * (1.0 - t)
		bytes.encode_s16(i * 2, int(clampf(v * 0.8, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = bytes
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = n
	return wav
