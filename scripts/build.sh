#!/bin/bash
# Builds Captain, installs it to /Applications (required for system extensions), and launches it.
#
#   CAPTAIN_TEAM_ID=ABCDE12345 ./scripts/build.sh   # full build with the virtual camera (paid team)
#   ./scripts/build.sh                              # preview build, no virtual camera (personal team)
#   ./scripts/build.sh --no-install                 # build only
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ -n "${CAPTAIN_TEAM_ID:-}" ]]; then
  SPEC=project.yml
  echo "Full build (with virtual camera) for team $CAPTAIN_TEAM_ID"
else
  export CAPTAIN_TEAM_ID=NWK93BVFJZ
  SPEC=project-preview.yml
  echo "Preview build (no virtual camera). Set CAPTAIN_TEAM_ID to a paid team for the full build."
fi

rm -rf Captain.xcodeproj
xcodegen generate --spec "$SPEC"

# A fresh build number every time so macOS replaces the installed camera extension.
BUILD_NUMBER="$(date +%s)"

xcodebuild \
  -project Captain.xcodeproj \
  -scheme Captain \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet \
  build

APP="build/DerivedData/Build/Products/Release/Captain.app"

if [[ "${1:-}" == "--no-install" ]]; then
  echo "Built $APP"
  exit 0
fi

pkill -x Captain 2>/dev/null || true
sleep 0.5
rm -rf /Applications/Captain.app
cp -R "$APP" /Applications/Captain.app
open /Applications/Captain.app
echo "Installed and launched /Applications/Captain.app (build $BUILD_NUMBER)"
