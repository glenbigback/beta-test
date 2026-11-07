extends Node
# Online rooms (autoload "Net"). Talks to server/gorilla_server.py over plain TCP, one JSON object per line.
#
#   Net.join_room("ABC123")   join / create a private room by code
#   Net.join_room("")         join a random public room
#   Net.leave_room()
#
# The server address comes from project.godot ([gorilla_net] server_address / port).
# While you are in a room your head + hands are sent 20x/s and every other player in the room
# is shown as a gorilla (Scripts/remote_player.gd).

signal status_changed # status text changed
signal room_joined(code:String)
signal join_failed(msg:String)
signal room_left
signal roster_changed # someone joined / left

enum State { OFFLINE, CONNECTING, ONLINE }

const SEND_HZ := 20.0
const PING_EVERY := 5.0
const CONNECT_TIMEOUT := 8.0
const POSE_SCALE := 1000.0 # poses go over the wire as integers (millimetres / thousandths)
const POSE_LEN := 21 # keep in sync with player.gd get_net_pose() and the server
const RemotePlayerScript := preload("res://Scripts/remote_player.gd")

var server_address:String = "127.0.0.1"
var server_port:int = 7777
var state:State = State.OFFLINE
var room_code:String = ""
var status:String = ""

var local_name:String = "GORILLA"
var local_color:Color = Color.WHITE
var local_has_color:bool = false # false = keep the model's own fur colour

var _tcp := StreamPeerTCP.new()
var _buf := PackedByteArray()
var _want:Dictionary = {} # join request waiting for the connection to come up
var _remotes:Dictionary = {} # peer id -> remote player node
var _send_accum := 0.0
var _ping_accum := 0.0
var _connect_time := 0.0
var _rig:Node = null

func _ready() -> void:
	server_address = str(ProjectSettings.get_setting("gorilla_net/server_address", server_address))
	server_port = int(ProjectSettings.get_setting("gorilla_net/port", server_port))
	set_process(false)

func is_in_room() -> bool:
	return room_code != ""

func player_count() -> int:
	return _remotes.size() + (1 if is_in_room() else 0)

# --- API used by the Gorilla Computer ----------------------------------------------------------

func set_profile(player_name:String, color:Color, has_color:bool) -> void:
	var changed := player_name != local_name or has_color != local_has_color or color != local_color
	local_name = player_name
	local_color = color
	local_has_color = has_color
	if changed and state == State.ONLINE and is_in_room():
		_send({"t": "profile", "name": local_name, "color": _color_json()})

# code "" = random public room
func join_room(code:String) -> void:
	_want = {"t": "join", "code": code}
	match state:
		State.OFFLINE:
			_connect()
		State.ONLINE:
			_flush_want()
		_:
			pass # still connecting; the request goes out as soon as we are connected
	_set_status("CONNECTING TO SERVER...")

func leave_room() -> void:
	_want = {}
	if state == State.ONLINE and is_in_room():
		_send({"t": "leave"})
	_disconnect()
	_set_status("")
	room_left.emit()

# --- connection --------------------------------------------------------------------------------

func _connect() -> void:
	_tcp = StreamPeerTCP.new()
	_buf.clear()
	_connect_time = 0.0
	var err := _tcp.connect_to_host(server_address, server_port)
	if err != OK:
		_fail("CANNOT REACH SERVER")
		return
	state = State.CONNECTING
	set_process(true)

func _disconnect() -> void:
	if _tcp.get_status() != StreamPeerTCP.STATUS_NONE:
		_tcp.disconnect_from_host()
	state = State.OFFLINE
	room_code = ""
	_buf.clear()
	_clear_remotes()
	set_process(false)

func _fail(msg:String) -> void:
	_want = {}
	_disconnect()
	_set_status(msg)
	join_failed.emit(msg)

func _flush_want() -> void:
	if _want.is_empty():
		return
	var req := _want
	_want = {}
	req["name"] = local_name
	req["color"] = _color_json()
	_send(req)
	_set_status("JOINING ROOM...")

func _color_json() -> Variant:
	if not local_has_color:
		return null
	return [snappedf(local_color.r, 0.001), snappedf(local_color.g, 0.001), snappedf(local_color.b, 0.001)]

func _set_status(text:String) -> void:
	status = text
	status_changed.emit()

func _send(msg:Dictionary) -> void:
	if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	_tcp.put_data((JSON.stringify(msg) + "\n").to_utf8_buffer())

# --- frame loop --------------------------------------------------------------------------------

func _process(delta:float) -> void:
	_tcp.poll()
	var st := _tcp.get_status()
	if st == StreamPeerTCP.STATUS_CONNECTING:
		_connect_time += delta
		if _connect_time > CONNECT_TIMEOUT:
			_fail("CONNECTION TIMED OUT")
		return
	if st != StreamPeerTCP.STATUS_CONNECTED:
		if state == State.ONLINE:
			var was_in_room := is_in_room()
			_disconnect()
			_set_status("CONNECTION LOST")
			if was_in_room:
				room_left.emit()
		else:
			_fail("CANNOT REACH SERVER")
		return
	if state == State.CONNECTING:
		state = State.ONLINE
		_tcp.set_no_delay(true)
		_ping_accum = 0.0
		_flush_want()
	_read()

	_ping_accum += delta
	if _ping_accum >= PING_EVERY:
		_ping_accum = 0.0
		_send({"t": "ping"})
	if is_in_room():
		_send_accum += delta
		if _send_accum >= 1.0 / SEND_HZ:
			_send_accum = 0.0
			_send_pose()

func _read() -> void:
	var n := _tcp.get_available_bytes()
	if n > 0:
		var res := _tcp.get_data(n)
		if res[0] == OK:
			_buf.append_array(res[1])
	while true:
		var i := _buf.find(10)
		if i < 0:
			break
		var line := _buf.slice(0, i).get_string_from_utf8()
		_buf = _buf.slice(i + 1)
		_handle(line)
	if _buf.size() > 65536:
		_buf.clear() # a line this long never comes from our server

func _send_pose() -> void:
	if _rig == null or not is_instance_valid(_rig):
		_rig = get_tree().get_first_node_in_group("gorilla_rig")
	if _rig == null or not _rig.has_method("get_net_pose"):
		return
	var pose:PackedFloat32Array = _rig.get_net_pose()
	if pose.size() != POSE_LEN:
		return
	var out:Array = []
	for v in pose:
		out.append(roundi(v * POSE_SCALE))
	_send({"t": "pose", "d": out})

# --- messages from the server ------------------------------------------------------------------

func _handle(line:String) -> void:
	var msg = JSON.parse_string(line)
	if typeof(msg) != TYPE_DICTIONARY:
		return
	match str(msg.get("t", "")):
		"joined":
			_clear_remotes()
			room_code = str(msg.get("code", ""))
			var peers = msg.get("peers", [])
			if typeof(peers) == TYPE_ARRAY:
				for p in peers:
					if typeof(p) == TYPE_DICTIONARY:
						_add_remote(p)
			_set_status("")
			room_joined.emit(room_code)
			roster_changed.emit()
		"join_failed":
			var reason := str(msg.get("msg", "JOIN FAILED"))
			_want = {}
			_disconnect() # nothing to stay connected for
			_set_status(reason)
			join_failed.emit(reason)
		"peer_joined":
			_add_remote(msg)
			roster_changed.emit()
		"peer_left":
			_remove_remote(int(msg.get("id", -1)))
			roster_changed.emit()
		"profile":
			var r = _remotes.get(int(msg.get("id", -1)))
			if r != null:
				r.set_profile(str(msg.get("name", "")), _parse_color(msg.get("color")))
		"pose":
			var r2 = _remotes.get(int(msg.get("id", -1)))
			var d = msg.get("d")
			if r2 != null and typeof(d) == TYPE_ARRAY and d.size() == POSE_LEN:
				var pose := PackedFloat32Array()
				for v in d:
					pose.append(float(v) / POSE_SCALE)
				r2.set_pose(pose)
		"left":
			pass # we already cleaned up in leave_room()

func _parse_color(v) -> Variant:
	if typeof(v) == TYPE_ARRAY and v.size() == 3:
		return Color(clampf(float(v[0]), 0.0, 1.0), clampf(float(v[1]), 0.0, 1.0), clampf(float(v[2]), 0.0, 1.0))
	return null

func _add_remote(info:Dictionary) -> void:
	var id := int(info.get("id", -1))
	if id < 0 or _remotes.has(id):
		return
	var rp = RemotePlayerScript.new()
	rp.name = "Remote%d" % id
	rp.setup(id, str(info.get("name", "GORILLA")), _parse_color(info.get("color")))
	add_child(rp)
	_remotes[id] = rp

func _remove_remote(id:int) -> void:
	var rp = _remotes.get(id)
	if rp != null:
		_remotes.erase(id)
		rp.queue_free()

func _clear_remotes() -> void:
	for rp in _remotes.values():
		rp.queue_free()
	_remotes.clear()
