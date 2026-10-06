#!/bin/zsh
set -eu
orbit_root="${0:A:h:h}"
cd "$orbit_root"
swift build -c release
orbit_bin="$(swift build -c release --show-bin-path)"
orbit_app="$orbit_root/build/Orbit.app"
mkdir -p "$orbit_app/Contents/MacOS" "$orbit_app/Contents/Resources"
cp "$orbit_bin/Orbit" "$orbit_app/Contents/MacOS/Orbit"
ditto "$orbit_bin/Orbit_OrbitDesktop.bundle" "$orbit_app/Contents/Resources/Orbit_OrbitDesktop.bundle"
cp "$orbit_root/Info.plist" "$orbit_app/Contents/Info.plist"
if [[ -f "$orbit_root/assets/Orbit.icns" ]]; then cp "$orbit_root/assets/Orbit.icns" "$orbit_app/Contents/Resources/Orbit.icns"; fi
codesign --force --deep --sign - "$orbit_app"
codesign --verify --deep --strict "$orbit_app"
print "App: $orbit_app"
