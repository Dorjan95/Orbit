#!/bin/zsh
set -eu
orbit_root="${0:A:h:h}"
"$orbit_root/scripts/build.sh"
orbit_target="/Applications/Orbit.app"
if pgrep -f '/Applications/Orbit.app/Contents/MacOS/' >/dev/null; then
  print 'Chiudi Orbit dal menu prima di installare la nuova versione.' >&2
  exit 1
fi
if [[ -d "$orbit_target" ]]; then
  orbit_backup="/Applications/Orbit.backup-$(date +%Y%m%d-%H%M%S).app"
  mv "$orbit_target" "$orbit_backup"
  print "Backup: $orbit_backup"
fi
ditto "$orbit_root/build/Orbit.app" "$orbit_target"
codesign --verify --deep --strict "$orbit_target"
open "$orbit_target"
