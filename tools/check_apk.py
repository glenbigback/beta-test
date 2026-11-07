#!/usr/bin/env python3
"""Checks an exported Godot APK for what it needs to run as a Quest VR game with online rooms.

    python3 check_apk.py build/GorillaLocomotion.apk      (a .zip containing one .apk also works)
"""
import sys
import zipfile


def load_apk(path):
    z = zipfile.ZipFile(path)
    names = z.namelist()
    if "AndroidManifest.xml" not in names:
        apks = [n for n in names if n.lower().endswith(".apk")]
        if len(apks) != 1:
            sys.exit("no AndroidManifest.xml and not exactly one .apk inside: " + path)
        import io
        z = zipfile.ZipFile(io.BytesIO(z.read(apks[0])))
        names = z.namelist()
    return z, names


def manifest_has(data, text):
    # the binary manifest keeps its strings as UTF-16LE or UTF-8, depending on the build
    return text.encode("utf-16le") in data or text.encode("utf-8") in data


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    z, names = load_apk(sys.argv[1])
    manifest = z.read("AndroidManifest.xml")
    libs = [n for n in names if n.startswith("lib/")]
    print("native libs:", ", ".join(sorted(libs)) or "(none)")
    print()

    checks = [
        ("arm64 Godot engine library",
         "lib/arm64-v8a/libgodot_android.so" in names,
         "Export with architectures/arm64-v8a ticked."),
        ("OpenXR loader (lib/arm64-v8a/libopenxr_loader.so)",
         "lib/arm64-v8a/libopenxr_loader.so" in names,
         "Install the 'Godot OpenXR Vendors' plugin and tick its Meta entry under Plugins in the export preset. "
         "Without the loader the game cannot start OpenXR and runs as a flat 2D app (or not at all)."),
        ("manifest declares a head-tracked VR app (android.hardware.vr.headtracking)",
         manifest_has(manifest, "android.hardware.vr.headtracking"),
         "Set XR Mode to OpenXR in the export preset."),
        ("manifest lists Quest devices (com.oculus.supportedDevices)",
         manifest_has(manifest, "com.oculus.supportedDevices"),
         "Comes from the Meta part of the OpenXR Vendors plugin: tick Meta under Plugins and set Quest Support."),
        ("INTERNET permission (needed for online rooms)",
         manifest_has(manifest, "android.permission.INTERNET"),
         "Tick Internet under Permissions in the export preset."),
    ]
    bad = 0
    for label, ok, fix in checks:
        print(("PASS  " if ok else "FAIL  ") + label)
        if not ok:
            bad += 1
            print("      -> " + fix)
    print()
    print("All good." if bad == 0 else f"{bad} problem(s) found.")
    sys.exit(1 if bad else 0)


main()
