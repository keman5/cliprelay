#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../cliprelay"

usage() {
  cat <<'EOF'
Usage: scripts/build.sh [--mac-only | --device <UDID>]
       scripts/build.sh --app-store <ios|macos>

The default builds and installs ClipRelay on this Mac and the QA simulator.
--app-store creates a Release archive and exports a local IPA or PKG.
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --app-store)
    if [[ $# != 2 ]]; then
      usage >&2
      exit 2
    fi
    case "$2" in
      ios) scheme=ClipRelayPhone; destination=generic/platform=iOS; extension=ipa ;;
      macos) scheme=ClipRelayMac; destination=generic/platform=macOS; extension=pkg ;;
      *) usage >&2; exit 2 ;;
    esac
    ;;
  ''|--mac-only|--device|--mac-view-qa|--keyboard-setup-qa|--history-ui-qa|--safari-link-qa)
    exec ./build.sh "$@"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

./build.sh --prepare

build_number=$(date -u +%y%m%d%H%M%S)
build_root="${CLIPRELAY_BUILD_ROOT:-$HOME/Library/Caches/ClipRelayBuild}"
mkdir -p "$build_root/app-store/$2"
release_root=$(cd "$build_root/app-store/$2" && pwd -P)
release_dir="$release_root/$build_number"
mkdir "$release_dir"
archive="$release_dir/ClipRelay.xcarchive"
export_dir="$release_dir/export"
export_options="$release_dir/ExportOptions.plist"

cat > "$export_options" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>export</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
</dict>
</plist>
EOF

xcodebuild -quiet -project ClipRelay.xcodeproj -scheme "$scheme" -configuration Release \
  -destination "$destination" -derivedDataPath "$release_root/DerivedData" \
  -archivePath "$archive" CURRENT_PROJECT_VERSION="$build_number" archive
xcodebuild -quiet -exportArchive -archivePath "$archive" \
  -exportPath "$export_dir" -exportOptionsPlist "$export_options"

shopt -s nullglob
packages=("$export_dir"/*."$extension")
if [[ ${#packages[@]} -eq 0 ]]; then
  printf 'No .%s was exported to %s\n' "$extension" "$export_dir" >&2
  exit 1
fi
printf 'Archive: %s\n' "$archive"
printf 'Package: %s\n' "${packages[@]}"
