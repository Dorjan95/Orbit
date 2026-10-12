#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE="build/Orbit.app"
DESTINATION="${1:-/Applications/Orbit.app}"
if [ ! -d "$SOURCE" ]; then
  echo "Compila prima l'app: ./scripts/build-app.sh" >&2
  exit 1
fi
if pgrep -x Jarvis >/dev/null || pgrep -x Orbit >/dev/null; then
  echo "Chiudi Orbit (o la versione precedente Jarvis) prima di aggiornare l'app." >&2
  exit 1
fi
# Keep one active installation when upgrading from the previous app name.
if [ "$DESTINATION" = /Applications/Orbit.app ] && [ -e /Applications/Jarvis.app ]; then
  LEGACY_BACKUP="/Applications/Jarvis.backup-$(date +%Y%m%d-%H%M%S).app"
  mv /Applications/Jarvis.app "$LEGACY_BACKUP"
  echo "Versione Jarvis salvata: $LEGACY_BACKUP"
fi
if [ -e "$DESTINATION" ]; then
  BACKUP="${DESTINATION%.app}.backup-$(date +%Y%m%d-%H%M%S).app"
  mv "$DESTINATION" "$BACKUP"
  echo "Versione precedente salvata: $BACKUP"
fi
mkdir -p "$(dirname "$DESTINATION")"
ditto "$SOURCE" "$DESTINATION"
codesign --verify --deep --strict "$DESTINATION"
open "$DESTINATION"
echo "Installato: $DESTINATION"
