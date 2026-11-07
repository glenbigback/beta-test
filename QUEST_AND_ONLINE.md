# Quest export + online rooms

## 1. Why the old APK was not a VR app

`tools/check_apk.py` on the old APK showed: no `libopenxr_loader.so`, no VR/head-tracking entries in the
manifest, no Quest device list, and no INTERNET permission. Godot only adds those when the export preset
uses OpenXR **and** the OpenXR Vendors plugin is installed. Run the checker on every new export:

    python3 tools/check_apk.py build/GorillaLocomotion.apk

## 2. Export for Quest (Godot 4.3, one-time setup)

1. Install JDK 17 and the Android SDK (platform-tools, build-tools 34.0.0, platform 34, cmdline-tools, CMake 3.10.2,
   NDK 23.2.8568313 -- Godot's "Exporting for Android" docs list the exact versions for your 4.x release).
   Point Editor > Editor Settings > Export > Android at the SDK and JDK, and at a debug keystore
   (the same docs explain how to create `debug.keystore` with `keytool`).
2. AssetLib tab > search **Godot OpenXR Vendors** > download the release made for Godot 4.3 > install.
   Project > Project Settings > Plugins > enable it.
3. Project > **Install Android Build Template** (the preset already has Gradle build switched on).
4. Project > Export. The "Meta Quest" preset is already there. Check these in the dialog:
   - Gradle Build: **on**, Architectures: **arm64-v8a only**
   - XR Features > XR Mode: **OpenXR**
   - Plugins: tick the **Meta** entry of the OpenXR Vendors plugin and set its Quest Support to Required
     (option names differ a little between plugin versions)
   - Permissions: **Internet** ticked
   - Package > Unique Name: change `com.example.gorillalocomotion` to your own id
5. Export Project (debug). Run `tools/check_apk.py` on the result: every line should say PASS.
6. Install: enable Developer Mode for your Quest in the Meta Horizon phone app, then
   `adb install -r build/GorillaLocomotion.apk`. It appears under Library > Unknown Sources.

## 3. Online rooms

The Gorilla Computer's ROOM and RANDOM ROOM now really connect. Players in the same room see each other as
gorillas (same model and arm IK as you) with a name tag and their fur colour.

### Run the server (any machine with Python 3.8+, no packages needed)

    cd server
    python3 gorilla_server.py --host 0.0.0.0 --port 7777

Open **TCP port 7777** on that machine / router. For internet play use a cheap VPS, or forward the port at home.
`python3 server/test_server.py` runs the server's own test suite.

### Point the game at it

Edit `project.godot`:

    [gorilla_net]
    server_address="your.server.ip.or.hostname"
    port=7777

then export again. (Testing on one PC: leave 127.0.0.1 and start the server locally.)

### Rooms

- ROOM + a code (letters/digits, max 6): joins or creates that **private** room. Share the code with friends.
- RANDOM ROOM: joins the fullest **public** room that has space, or opens a new one. 10 players per room.
- Computer menu, DOWN ARROW for page 2 > F2: LEAVE ROOM.

### Not in yet

Tagging / infection rules (option A), voice chat, synced cosmetics (others see name + fur colour only),
and players cannot push each other -- hands only collide with the map.

### Testing status

The server was tested end to end (`server/test_server.py`, plus a real client on the command line).
The Godot-side code (`Scripts/net.gd`, `Scripts/remote_player.gd` and the computer/player patches) could
not be run where I wrote it, because there is no Godot there. If Godot prints an error on first launch,
send me the Output panel text and I will fix it.
