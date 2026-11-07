extends Node
# Plays a music track while the player is inside the cave system, fading it in and out.
# Put the audio file in Map/audio/ named cave_wave.ogg (or .mp3 / .wav). If the file is missing
# nothing happens (one warning is printed).
#
# "Inside the cave" = the first solid thing straight above your head is part of the cave mesh
# (its ceiling). Standing outside, or in the canyon / forest, the first thing above you is sky,
# a tree or some other part of the map, so the music fades out.

const EXTENSIONS := ["ogg", "mp3", "wav"]
const SILENT_DB := -60.0

@export var track_name:String = "cave_wave"
@export var folder:String = "res://Map/audio"
@export var play_volume_db:float = -6.0
@export var fade_seconds:float = 1.5
@export var cave_mesh_name:String = "Cave_fixed" # the map node that holds the cave walls and floor
@export var max_ceiling_distance:float = 40.0 # how far above your head to look for the ceiling

var _audio:AudioStreamPlayer
var _head:Node3D
var _cave:Node
var _bounds:AABB
var _inside:bool = false
var _check_timer:float = 0.0

func setup(map:Node, head:Node3D) -> void:
	set_physics_process(false)
	_head = head
	if _head == null:
		return
	_cave = map.find_child(cave_mesh_name, true, false)
	if _cave == null:
		push_warning("CaveMusic: no node called '%s' in the map" % cave_mesh_name)
		return
	var stream := _load_track()
	if stream == null:
		push_warning("CaveMusic: no %s.ogg / .mp3 / .wav found in %s -- the caves will stay quiet" % [track_name, folder])
		return
	_set_loop(stream)
	# rough box around the cave, so we only do the ceiling check when you are somewhere near it
	var have_bounds := false
	var meshes:Array = []
	if _cave is MeshInstance3D:
		meshes.append(_cave)
	meshes.append_array(_cave.find_children("*", "MeshInstance3D", true, false))
	for mi in meshes:
		var box:AABB = (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
		_bounds = box if not have_bounds else _bounds.merge(box)
		have_bounds = true
	if not have_bounds:
		return
	_audio = AudioStreamPlayer.new()
	_audio.name = "CaveMusicPlayer"
	_audio.stream = stream
	_audio.volume_db = SILENT_DB
	_audio.finished.connect(_on_finished)
	add_child(_audio)
	set_physics_process(true)

func _load_track() -> AudioStream:
	for ext in EXTENSIONS:
		var path := "%s/%s.%s" % [folder, track_name, ext]
		if ResourceLoader.exists(path):
			var s := load(path) as AudioStream
			if s != null:
				return s
	return null

func _set_loop(stream:AudioStream) -> void:
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	elif stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true
	elif stream is AudioStreamWAV:
		var wav := stream as AudioStreamWAV
		var bytes_per_frame := 1 if wav.format == AudioStreamWAV.FORMAT_8_BITS else 2
		if wav.stereo:
			bytes_per_frame *= 2
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = int(wav.data.size() / float(bytes_per_frame))

func _on_finished() -> void:
	# fallback for formats that did not loop on their own
	if _inside and _audio != null:
		_audio.play()

func _physics_process(delta:float) -> void:
	_check_timer -= delta
	if _check_timer <= 0.0:
		_check_timer = 0.2
		_inside = _is_in_cave()
	var target := play_volume_db if _inside else SILENT_DB
	var step := (play_volume_db - SILENT_DB) / maxf(fade_seconds, 0.05) * delta
	_audio.volume_db = move_toward(_audio.volume_db, target, step)
	if _audio.volume_db <= SILENT_DB + 0.01:
		if _audio.playing:
			_audio.stop() # starts again from the beginning next time you walk in
	elif not _audio.playing:
		_audio.play()

func _is_in_cave() -> bool:
	var p := _head.global_position
	if not _bounds.grow(1.0).has_point(p):
		return false
	var space := _head.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(p, p + Vector3.UP * max_ceiling_distance)
	query.collision_mask = 1 # the map; the player and hands are on layer 2
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return false
	var collider := hit.get("collider") as Node
	return collider != null and (_cave == collider or _cave.is_ancestor_of(collider))
