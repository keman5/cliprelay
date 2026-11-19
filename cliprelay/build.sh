#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
device=
mac_only=false
case "${1:-}" in
  --mac-only) mac_only=true ;;
  --device)
    if [[ $# != 2 || -z "$2" || "$2" == -* ]]; then
      echo "Usage: $0 --device <iPhone UDID>" >&2
      exit 2
    fi
    device=$2
    ;;
esac
command -v go >/dev/null && go clean -cache
if [[ "${1:-}" == --keyboard-setup-qa ]]; then
  qa_dir=$(mktemp -d)
  trap 'rm -rf "$qa_dir"' EXIT
  swiftc Shared/KeyboardSetupCheck.swift scripts/keyboard-setup-qa.swift -o "$qa_dir/check"
  "$qa_dir/check"
  exit
fi
build_root="${CLIPRELAY_BUILD_ROOT:-$HOME/Library/Caches/ClipRelayBuild}"
if [[ "$mac_only" == false && -z "$device" && "${1:-}" != --mac-view-qa ]]; then
  sim="${CLIPRELAY_SIM:-$(xcrun simctl list devices available -j | node -e 'let s="";process.stdin.on("data",v=>s+=v).on("end",()=>console.log(Object.values(JSON.parse(s).devices).flat().find(d=>d.name==="ClipRelay-QA")?.udid||""))')}"
  if [[ -z "$sim" ]]; then
    runtime=$(xcrun simctl list runtimes -j | node -e '
      const { runtimes } = JSON.parse(require("fs").readFileSync(0,"utf8"));
      const runtime = runtimes.filter(r => r.isAvailable && r.identifier.startsWith("com.apple.CoreSimulator.SimRuntime.iOS-"))
        .sort((a,b) => b.version.localeCompare(a.version,"en",{numeric:true}))[0];
      if (!runtime) process.exit(1);
      console.log(runtime.identifier);
    ')
    sim=$(xcrun simctl create ClipRelay-QA com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$runtime")
  fi
  if ! xcrun simctl list devices booted | grep -F "$sim" >/dev/null; then xcrun simctl boot "$sim"; fi
fi
mkdir -p Resources "$build_root"
if [[ ! -s Keyboard/pinyin.json || scripts/make-pinyin.swift -nt Keyboard/pinyin.json ]]; then
  swift scripts/make-pinyin.swift Keyboard/pinyin.json
fi
xcodegen generate
build_number=$(date -u +%y%m%d%H%M%S)

build_target() {
  local platform=$1 scheme=$2 destination=$3
  shift 3
  local data_path="$build_root/$platform"
  xcodebuild -quiet -project ClipRelay.xcodeproj -scheme "$scheme" -configuration Debug \
    -destination "$destination" -derivedDataPath "$data_path" \
    SYMROOT="$data_path/Build/Products" OBJROOT="$data_path/Build/Intermediates.noindex" \
    CURRENT_PROJECT_VERSION="$build_number" "$@" build
}

if [[ "${1:-}" == --history-ui-qa ]]; then
  xcodebuild -quiet -project ClipRelay.xcodeproj -scheme ClipRelayPhone -configuration Debug \
    -destination "id=$sim" -derivedDataPath "$build_root/ios" \
    SYMROOT="$build_root/ios/Build/Products" OBJROOT="$build_root/ios/Build/Intermediates.noindex" \
    CURRENT_PROJECT_VERSION="$build_number" -parallel-testing-enabled NO test
  exit
fi
build_target mac ClipRelayMac 'platform=macOS' CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Apple Development'
app="$build_root/mac/Build/Products/Debug/ClipRelay.app"
codesign --verify --deep --strict "$app"
if [[ "${1:-}" == --mac-view-qa ]]; then
  exec "$app/Contents/MacOS/ClipRelay" --view-qa
fi
if [[ "$mac_only" == false && -z "$device" ]]; then
  build_target ios ClipRelayPhone "id=$sim"
fi
target=/Applications/ClipRelay.app
if [[ -d "$target" && "$(defaults read "$target/Contents/Info" CFBundleIdentifier)" != cc.macseek.cliprelay.mac ]]; then exit 1; fi
stage=$(mktemp -d /Applications/.cliprelay-install.XXXXXX)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/ClipRelay.app"
if [[ -d "$target" ]]; then mv "$target" "$stage/previous.app"; fi
if ! mv "$stage/ClipRelay.app" "$target"; then [[ ! -d "$stage/previous.app" ]] || mv "$stage/previous.app" "$target"; exit 1; fi
if [[ -d .artifacts ]]; then rm -rf .artifacts; fi
echo "Installed ClipRelay $build_number on Mac"
if [[ "$mac_only" == true ]]; then exit 0; fi
if [[ -n "$device" ]]; then
  build_target ios ClipRelayPhone "id=$device" -allowProvisioningUpdates
  phone_app="$build_root/ios/Build/Products/Debug-iphoneos/ClipRelay.app"
  codesign --verify --deep --strict "$phone_app"
  xcrun devicectl device install app --device "$device" "$phone_app"
else
  xcrun simctl bootstatus "$sim" -b
  xcrun simctl install "$sim" "$build_root/ios/Build/Products/Debug-iphonesimulator/ClipRelay.app"
  echo "Installed ClipRelay $build_number on simulator $sim"
fi
