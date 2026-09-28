#!/bin/sh
set -eu

# Invoked by Xcode before outer app signing. Build artifacts only; this does
# not register the host, load an extension, or change browser permissions.
bridge_resources="${1:?Expected the app resources directory}"
bridge_root="${SRCROOT:?Expected Xcode SRCROOT}"
bridge_destination="$bridge_resources/ChromeBridge"
mkdir -p "$bridge_destination"
bridge_binary="$bridge_destination/ChromeBridgeHost"
bridge_slices=$(mktemp -d "${TMPDIR:-/tmp}/computa-chrome-bridge.XXXXXX")
trap 'rm -r "$bridge_slices"' EXIT

# Xcode sets ARCHS to the slices in the enclosing app. A direct local invocation
# keeps the original arm64 default.
set -f
set --
for architecture in ${ARCHS:-arm64}; do
  case "$architecture" in
    arm64|x86_64) ;;
    *) echo "Unsupported Chrome bridge architecture: $architecture" >&2; exit 1 ;;
  esac
  slice="$bridge_slices/ChromeBridgeHost-$architecture"
  xcrun swiftc -swift-version 6 -O \
    -target "$architecture-apple-macos${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    "$bridge_root/Sources/Computa/Runtime/ChromeBridgeIPC.swift" \
    "$bridge_root/Sources/Computa/Runtime/ChromeBridgeIdentity.swift" \
    "$bridge_root/Sources/ChromeBridgeHost/main.swift" \
    -o "$slice"
  set -- "$@" "$slice"
done
if [ "$#" -eq 1 ]; then
  cp "$1" "$bridge_binary"
else
  /usr/bin/lipo -create "$@" -output "$bridge_binary"
fi
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  /usr/bin/codesign --force --options runtime --timestamp=none \
    --identifier com.ahmedelamin.LocalCodex.ChromeBridgeHost \
    --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$bridge_binary"
fi
