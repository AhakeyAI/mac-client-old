#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$ROOT_DIR/build"
ARCH="${ARCH:-$(uname -m)}"
DOTNET_BIN="${DOTNET_BIN:-dotnet}"
SWIFTC_BIN="${SWIFTC_BIN:-swiftc}"

case "$ARCH" in
  x86_64)
    RID="osx-x64"
    ;;
  arm64)
    RID="osx-arm64"
    ;;
  *)
    echo "Unsupported macOS architecture: $ARCH" >&2
    exit 1
    ;;
esac

if ! command -v "$DOTNET_BIN" >/dev/null 2>&1; then
  cat <<EOF >&2
Missing required command: $DOTNET_BIN

Install .NET SDK 8 first, for example:
  brew install --cask dotnet-sdk
EOF
  exit 1
fi

if ! command -v "$SWIFTC_BIN" >/dev/null 2>&1; then
  cat <<EOF >&2
Missing required command: $SWIFTC_BIN

Install Xcode Command Line Tools first:
  xcode-select --install
EOF
  exit 1
fi

PUBLISH_DIR="$BUILD_DIR/publish-$RID"
APP_DIR="$DIST_DIR/BLETcpBridge.app"
BRIDGE_RESOURCES_DIR="$APP_DIR/Contents/Resources/bridge"

rm -rf "$PUBLISH_DIR" "$APP_DIR"
mkdir -p "$PUBLISH_DIR" "$BRIDGE_RESOURCES_DIR" "$APP_DIR/Contents/MacOS"

"$DOTNET_BIN" publish \
  "$ROOT_DIR/BleTcpBridge.csproj" \
  -c Release \
  -r "$RID" \
  --self-contained true \
  -o "$PUBLISH_DIR"

"$SWIFTC_BIN" -O "$ROOT_DIR/ble_helper.swift" -o "$PUBLISH_DIR/ble_helper"

cp "$ROOT_DIR/app_bundle/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/app_bundle/BLETcpBridge" "$APP_DIR/Contents/MacOS/BLETcpBridge"
cp "$ROOT_DIR/app_bundle/run_bridge.command" "$BRIDGE_RESOURCES_DIR/run_bridge.command"

cp "$PUBLISH_DIR/BleTcpBridge" "$BRIDGE_RESOURCES_DIR/BleTcpBridge"
cp "$PUBLISH_DIR/ble_helper" "$BRIDGE_RESOURCES_DIR/ble_helper"
cp "$ROOT_DIR/ble_helper.swift" "$BRIDGE_RESOURCES_DIR/ble_helper.swift"

chmod +x \
  "$APP_DIR/Contents/MacOS/BLETcpBridge" \
  "$BRIDGE_RESOURCES_DIR/run_bridge.command" \
  "$BRIDGE_RESOURCES_DIR/BleTcpBridge" \
  "$BRIDGE_RESOURCES_DIR/ble_helper"

cat <<EOF
mac_bridge build finished.

Runtime identifier:
  $RID

App bundle:
  $APP_DIR
EOF
