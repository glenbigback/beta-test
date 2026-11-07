extends Node3D

var xr_interface: XRInterface

func _ready():
	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		print("OpenXR initialized successfully")

		# the headset's compositor paces the frames, not the (virtual) window
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		get_viewport().use_xr = true

		# Quest runs at 72 Hz unless you ask for more; arm-swing movement feels much better at 90+
		if xr_interface.has_signal("session_begun"):
			xr_interface.connect("session_begun", _on_session_begun)
	else:
		print("OpenXR not initialized, please check if your headset is connected")

func _on_session_begun() -> void:
	if not xr_interface.has_method("get_available_display_refresh_rates"):
		return
	var rates:Array = xr_interface.call("get_available_display_refresh_rates")
	for wanted in [90.0, 120.0, 80.0]:
		if rates.has(wanted):
			xr_interface.call("set_display_refresh_rate", wanted)
			print("XR refresh rate set to ", wanted)
			return
