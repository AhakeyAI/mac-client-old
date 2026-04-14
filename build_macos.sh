#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_VERSION="${APP_VERSION:-}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist-macos}"
RELEASE_DIR="${RELEASE_DIR:-$DIST_DIR/release}"
VENV_DIR="$ROOT_DIR/.venv"
RUNTIME_ENTITLEMENTS_FILE="$ROOT_DIR/macos_hardened_runtime.entitlements"
APP_BUNDLE_NAME="Vibecoding Keyboard.app"
APP_DISPLAY_NAME="Vibecoding Keyboard"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
CODESIGN_KEYCHAIN="${CODESIGN_KEYCHAIN:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARIZE_TARGET="${NOTARIZE_TARGET:-dmg}"
SKIP_DMG="${SKIP_DMG:-0}"

CONFIG_TOOL_DIR="$ROOT_DIR/vibe_code_config_tool-master"
HOOK_DIR="$CONFIG_TOOL_DIR/hook"
BRIDGE_DIR="$ROOT_DIR/mac_bridge"
ICON_SCRIPT="$CONFIG_TOOL_DIR/scripts/make_macos_icon.py"
ICON_TARGET="$CONFIG_TOOL_DIR/assets/macos/VibeCodeKeyboard.icns"
DMG_BACKGROUND_SCRIPT="$CONFIG_TOOL_DIR/scripts/make_dmg_background.py"

function log_step() {
  printf '\n==> %s\n' "$1"
}

function choose_python() {
  if [ -n "${PYTHON_BIN:-}" ] && command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    echo "$PYTHON_BIN"
    return
  fi

  local candidates=(python3.13 python3.12 python3.11 python3.10 python3)
  local candidate
  for candidate in "${candidates[@]}"; do
    if command -v "$candidate" >/dev/null 2>&1; then
      local version
      version="$("$candidate" - <<'PY'
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}")
PY
)"
      case "$version" in
        3.10|3.11|3.12|3.13)
          echo "$candidate"
          return
          ;;
      esac
    fi
  done

  return 1
}

function ensure_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

function ensure_venv() {
  local base_python="$1"
  local venv_python="$VENV_DIR/bin/python3"

  if [ ! -x "$venv_python" ]; then
    log_step "Creating virtual environment with: $("$base_python" --version 2>&1)"
    "$base_python" -m venv "$VENV_DIR"
  fi

  "$venv_python" - <<'PY' >/dev/null 2>&1 || {
import sys
sys.exit(0 if (3, 10) <= sys.version_info[:2] <= (3, 13) else 1)
PY
    rm -rf "$VENV_DIR"
    log_step "Recreating virtual environment with: $("$base_python" --version 2>&1)"
    "$base_python" -m venv "$VENV_DIR"
  }

  echo "$venv_python"
}

function clean_build_dir() {
  local dir="$1"
  rm -rf "$dir/build" "$dir/dist"
}

function resolve_app_version() {
  local python_bin="$1"
  "$python_bin" - <<PY
from pathlib import Path
import runpy

project_root = Path(r"$CONFIG_TOOL_DIR")
version_file = project_root / "src" / "core" / "app_version.py"
try:
    data = runpy.run_path(str(version_file))
    print(str(data.get("APP_VERSION", "1.0.2")).strip() or "1.0.2")
except Exception:
    print("1.0.2")
PY
}

function build_pyinstaller_app() {
  local dir="$1"
  local spec="$2"

  clean_build_dir "$dir"
  (
    cd "$dir"
    "$PYTHON_BIN" -m PyInstaller -y "$spec"
  )
}

function build_capswriter_helper() {
  local spec_name="$1"
  local helper_name="$2"
  local dist_path="$3"
  local work_path="$4"

  rm -rf "$dist_path" "$work_path"
  mkdir -p "$dist_path" "$work_path"
  (
    cd "$CONFIG_TOOL_DIR/capswriter"
    "$PYTHON_BIN" -m PyInstaller -y \
      --distpath "$dist_path" \
      --workpath "$work_path" \
      "$spec_name" 1>&2
  )
  printf '%s\n' "$dist_path/$helper_name"
}

function copy_app() {
  local source="$1"
  local target_dir="$2"
  rm -rf "$target_dir/$(basename "$source")"
  cp -R "$source" "$target_dir/"
}

function copy_dir_clean() {
  local source="$1"
  local target="$2"
  rm -rf "$target"
  mkdir -p "$(dirname "$target")"
  cp -R "$source" "$target"
  find "$target" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
  find "$target" -name '.DS_Store' -delete 2>/dev/null || true
  rm -rf "$target/logs"
}

function copy_capswriter_runtime() {
  local source="$1"
  local target="$2"
  local sensevoice_rel="models/SenseVoice-Small/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"

  rm -rf "$target"
  mkdir -p "$target"

  rsync -a \
    --delete \
    --exclude '__pycache__/' \
    --exclude '.DS_Store' \
    --exclude 'build/' \
    --exclude 'dist/' \
    --exclude 'logs/' \
    --exclude 'models/' \
    --exclude 'core_client_mac' \
    --exclude 'core_server' \
    --exclude 'core_client_mac_internal/' \
    --exclude 'core_server_internal/' \
    --exclude '.python-runtime/' \
    "$source/" \
    "$target/"

  mkdir -p "$target/$sensevoice_rel"
  cp "$source/$sensevoice_rel/model.int8.onnx" "$target/$sensevoice_rel/"
  cp "$source/$sensevoice_rel/tokens.txt" "$target/$sensevoice_rel/"

  if [ -f "$source/$sensevoice_rel/LICENSE" ]; then
    cp "$source/$sensevoice_rel/LICENSE" "$target/$sensevoice_rel/"
  fi

  find "$target" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
  find "$target" -name '.DS_Store' -delete 2>/dev/null || true
  rm -rf "$target/logs"
  mkdir -p "$target/logs"
  prepare_capswriter_python_runtime "$target"
  relocate_capswriter_python_runtime_links "$target"
  prepare_capswriter_launchers "$target"
}

function copy_capswriter_helper_bundle() {
  local source_dir="$1"
  local target_dir="$2"

  if [ ! -d "$source_dir" ]; then
    echo "CapsWriter helper bundle not found: $source_dir" >&2
    exit 1
  fi

  rsync -a \
    --exclude '.DS_Store' \
    "$source_dir/" \
    "$target_dir/"

  find "$target_dir" -name '.DS_Store' -delete 2>/dev/null || true
}

function prepare_capswriter_python_runtime() {
  local target="$1"
  local runtime_root="$target/.python-runtime"
  local versions_dir="$runtime_root/Python.framework/Versions"
  local runtime_home="$versions_dir/$PYTHON_VERSION_TAG"
  local site_packages="$runtime_root/site-packages"
  local stdlib_dir="$runtime_home/lib/python$PYTHON_VERSION_TAG"
  local helper_app="$runtime_home/Resources/Python.app"
  local helper_plist="$helper_app/Contents/Info.plist"
  local venv_site_packages="$VENV_DIR/lib/python$PYTHON_VERSION_TAG/site-packages"

  log_step "Embedding standalone CapsWriter Python runtime"
  rm -rf "$runtime_root"
  mkdir -p "$versions_dir"
  ditto "$PYTHON_BASE_PREFIX" "$runtime_home"
  ln -sfn "$PYTHON_VERSION_TAG" "$versions_dir/Current"

  mkdir -p "$site_packages"
  if [ ! -d "$venv_site_packages" ]; then
    echo "Missing virtualenv site-packages directory: $venv_site_packages" >&2
    exit 1
  fi

  rm -rf "$site_packages"
  mkdir -p "$site_packages"
  ditto "$venv_site_packages" "$site_packages"

  rm -rf \
    "$site_packages/pip" \
    "$site_packages"/pip-*.dist-info \
    "$site_packages/setuptools" \
    "$site_packages"/setuptools-*.dist-info \
    "$site_packages/wheel" \
    "$site_packages"/wheel-*.dist-info \
    "$site_packages/PyInstaller" \
    "$site_packages/pyinstaller" \
    "$site_packages"/pyinstaller-*.dist-info \
    "$site_packages/pyinstaller_hooks_contrib" \
    "$site_packages"/pyinstaller_hooks_contrib-*.dist-info \
    "$site_packages/altgraph" \
    "$site_packages"/altgraph-*.dist-info \
    "$site_packages/macholib" \
    "$site_packages"/macholib-*.dist-info \
    "$site_packages/PySide6" \
    "$site_packages"/pyside6-*.dist-info \
    "$site_packages"/pyside6_addons-*.dist-info \
    "$site_packages"/pyside6_essentials-*.dist-info \
    "$site_packages/shiboken6" \
    "$site_packages"/shiboken6-*.dist-info \
    "$site_packages/PIL" \
    "$site_packages"/pillow-*.dist-info \
    "$site_packages/qdarktheme" \
    "$site_packages"/qdarktheme-*.dist-info \
    "$site_packages/bleak" \
    "$site_packages"/bleak-*.dist-info \
    "$site_packages/qrcode" \
    "$site_packages"/qrcode-*.dist-info

  find "$runtime_root" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
  find "$runtime_root" -name '.DS_Store' -delete 2>/dev/null || true
  find "$runtime_root" -name '*.pyc' -delete 2>/dev/null || true

  rm -rf \
    "$stdlib_dir/test" \
    "$stdlib_dir/tkinter" \
    "$stdlib_dir/turtledemo" \
    "$stdlib_dir/idlelib" \
    "$stdlib_dir/ensurepip" \
    "$stdlib_dir/lib2to3"

  if [ -f "$helper_plist" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.vibekeyboard.capswriter.python" "$helper_plist" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.vibekeyboard.capswriter.python" "$helper_plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Vibecoding Keyboard Voice Runtime" "$helper_plist" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleName string Vibecoding Keyboard Voice Runtime" "$helper_plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Vibecoding Keyboard Voice Runtime" "$helper_plist" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Vibecoding Keyboard Voice Runtime" "$helper_plist"
    /usr/libexec/PlistBuddy -c "Set :NSMicrophoneUsageDescription Use the microphone for voice input." "$helper_plist" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string Use the microphone for voice input." "$helper_plist"
    /usr/libexec/PlistBuddy -c "Set :LSUIElement true" "$helper_plist" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$helper_plist"
  fi
}

function relocate_capswriter_python_runtime_links() {
  local target="$1"
  local runtime_root="$target/.python-runtime"
  local runtime_home="$runtime_root/Python.framework/Versions/$PYTHON_VERSION_TAG"
  local embedded_python="$runtime_home/Python"

  if [ ! -f "$embedded_python" ]; then
    echo "Missing embedded Python runtime: $embedded_python" >&2
    exit 1
  fi

  # python.org's framework binaries are copied with absolute dependencies on
  # /Library/Frameworks/Python.framework/Versions/X.Y/... After Developer ID
  # signing, dyld rejects loading that external framework because it has a
  # different Team ID. Rewrite every embedded Mach-O so it references the
  # in-app runtime via @loader_path-relative links instead.
  "$PYTHON_BIN" - "$runtime_root" "$runtime_home" "$PYTHON_VERSION_TAG" <<'PY'
import os
import stat
import subprocess
import sys

runtime_root = os.path.realpath(sys.argv[1])
runtime_home = os.path.realpath(sys.argv[2])
version = sys.argv[3]
system_root = f"/Library/Frameworks/Python.framework/Versions/{version}"


def is_macho_candidate(path: str) -> bool:
    try:
        st = os.stat(path)
    except OSError:
        return False
    if not stat.S_ISREG(st.st_mode):
        return False
    return bool(st.st_mode & 0o111) or path.endswith((".so", ".dylib"))


def run_otool(flag: str, path: str) -> list[str]:
    proc = subprocess.run(
        ["otool", flag, path],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        return []
    return [line.rstrip() for line in proc.stdout.splitlines()]


machos: list[str] = []
for dirpath, _, filenames in os.walk(runtime_root):
    for filename in filenames:
        candidate = os.path.join(dirpath, filename)
        if is_macho_candidate(candidate):
            machos.append(os.path.realpath(candidate))

machos = sorted(set(machos))

# First rewrite install IDs for embedded dylibs/framework binaries that still
# advertise their original python.org absolute path.
for candidate in machos:
    id_lines = run_otool("-D", candidate)
    if len(id_lines) < 2:
        continue
    old_id = id_lines[1].strip()
    if not old_id.startswith(system_root):
        continue
    relative_to_self = os.path.relpath(candidate, os.path.dirname(candidate))
    subprocess.run(
        ["install_name_tool", "-id", f"@loader_path/{relative_to_self}", candidate],
        check=True,
    )

# Then rewrite every dependency that still points at the copied system runtime.
for candidate in machos:
    dep_lines = run_otool("-L", candidate)[1:]
    seen: set[str] = set()
    for line in dep_lines:
        old_dep = line.strip().split(" (compatibility version", 1)[0]
        if not old_dep.startswith(system_root) or old_dep in seen:
            continue
        rel_suffix = old_dep[len(system_root):].lstrip("/")
        embedded_target = os.path.join(runtime_home, rel_suffix)
        if not os.path.exists(embedded_target):
            continue
        relative_to_target = os.path.relpath(
            os.path.realpath(embedded_target),
            os.path.dirname(candidate),
        )
        subprocess.run(
            [
                "install_name_tool",
                "-change",
                old_dep,
                f"@loader_path/{relative_to_target}",
                candidate,
            ],
            check=True,
        )
        seen.add(old_dep)
PY
}

function write_capswriter_python_launcher() {
  local target="$1"
  local script_name="$2"
  local launcher_path="$target/$script_name"

  cat >"$launcher_path" <<EOF
#!/bin/sh
set -eu

SCRIPT_DIR="\$(CDPATH= cd -- "\$(dirname "\$0")" && pwd)"
CONTENTS_DIR="\$(CDPATH= cd -- "\$SCRIPT_DIR/../.." && pwd)"
FRAMEWORKS_DIR="\$CONTENTS_DIR/Frameworks"
RUNTIME_HOME="\$SCRIPT_DIR/.python-runtime/Python.framework/Versions/$PYTHON_VERSION_TAG"
PYTHON_BIN="\$RUNTIME_HOME/bin/python3"
SCRIPT_PATH="\$SCRIPT_DIR/$script_name.py"
DATA_ROOT="\$HOME/Library/Application Support/VibeKeyboard/capswriter"
LOG_DIR="\$DATA_ROOT/logs"

export PYTHONHOME="\$RUNTIME_HOME"
export PYTHONPATH="\$SCRIPT_DIR/.python-runtime/site-packages:\$FRAMEWORKS_DIR:\$SCRIPT_DIR"
export PYTHONUNBUFFERED=1
export PYTHONIOENCODING=utf-8
export PYTHONNOUSERSITE=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPYCACHEPREFIX="\$DATA_ROOT/pycache"
export CAPSWRITER_HOME="\$SCRIPT_DIR"
export CAPSWRITER_DATA_DIR="\$DATA_ROOT"
export CAPSWRITER_LOG_DIR="\$LOG_DIR"
export CAPSWRITER_BOOTSTRAP_EXE="\$CONTENTS_DIR/MacOS/KeyboardConfig"
export QT_PLUGIN_PATH="\$FRAMEWORKS_DIR/PySide6/Qt/plugins"
export DYLD_FRAMEWORK_PATH="\$SCRIPT_DIR/.python-runtime:\$FRAMEWORKS_DIR/PySide6/Qt/lib:\$FRAMEWORKS_DIR\${DYLD_FRAMEWORK_PATH:+:\$DYLD_FRAMEWORK_PATH}"

mkdir -p "\$LOG_DIR" "\$DATA_ROOT/pycache"

if [ -x /usr/bin/arch ] && [ "\$(uname -m)" = "arm64" ]; then
  exec /usr/bin/arch -x86_64 "\$PYTHON_BIN" -u "\$SCRIPT_PATH" "\$@"
fi

exec "\$PYTHON_BIN" -u "\$SCRIPT_PATH" "\$@"
EOF

  chmod +x "$launcher_path"
}

function prepare_capswriter_launchers() {
  local target="$1"
  write_capswriter_python_launcher "$target" "core_server"
  write_capswriter_python_launcher "$target" "core_client_mac"
}

function build_capswriter_swift_helper() {
  local source="$1"
  local output="$2"

  if [ ! -f "$source" ]; then
    return
  fi

  local needs_build=0
  if [ ! -f "$output" ]; then
    needs_build=1
  elif [ "$source" -nt "$output" ]; then
    needs_build=1
  fi

  if [ "$needs_build" -eq 0 ]; then
    return
  fi

  if ! command -v swiftc >/dev/null 2>&1; then
    if [ -f "$output" ]; then
      echo "Warning: swiftc unavailable, reusing existing helper: $output" >&2
      return
    fi
    echo "Missing required command: swiftc" >&2
    echo "Install Xcode Command Line Tools first: xcode-select --install" >&2
    exit 1
  fi

  log_step "Building $(basename "$output")"
  swiftc -O "$source" -o "$output"
}

function prepare_capswriter_swift_helpers() {
  build_capswriter_swift_helper \
    "$CONFIG_TOOL_DIR/capswriter/focused_text_injector.swift" \
    "$CONFIG_TOOL_DIR/capswriter/focused_text_injector"

  build_capswriter_swift_helper \
    "$CONFIG_TOOL_DIR/capswriter/voice_input_bridge.swift" \
    "$CONFIG_TOOL_DIR/capswriter/voice_input_bridge"
}

function ensure_bridge_app() {
  local bridge_app="$BRIDGE_DIR/dist/BLETcpBridge.app"
  local bridge_backup=""

  if [ -d "$bridge_app" ]; then
    bridge_backup="$(mktemp -d "${TMPDIR:-/tmp}/blebridge-backup.XXXXXX")"
    cp -R "$bridge_app" "$bridge_backup/BLETcpBridge.app"
  fi

  if command -v dotnet >/dev/null 2>&1 && command -v swiftc >/dev/null 2>&1; then
    log_step "Building BLETcpBridge.app (mac_bridge)"
    chmod +x "$BRIDGE_DIR/build_app.sh"
    if "$BRIDGE_DIR/build_app.sh"; then
      rm -rf "$bridge_backup"
      return
    fi

    if [ -n "$bridge_backup" ] && [ -d "$bridge_backup/BLETcpBridge.app" ]; then
      rm -rf "$bridge_app"
      cp -R "$bridge_backup/BLETcpBridge.app" "$bridge_app"
      echo "Warning: BLETcpBridge.app rebuild failed, restored previous app bundle: $bridge_app" >&2
      rm -rf "$bridge_backup"
      return
    fi

    echo "BLETcpBridge.app rebuild failed and no existing app bundle is available." >&2
    rm -rf "$bridge_backup"
    exit 1
  fi

  if [ -d "$bridge_app" ]; then
    rm -rf "$bridge_backup"
    log_step "Reusing existing BLETcpBridge.app (dotnet/swiftc unavailable)"
    return
  fi

  rm -rf "$bridge_backup"

  if ! command -v dotnet >/dev/null 2>&1; then
    echo "Missing required command: dotnet" >&2
    echo >&2
    echo "Install .NET SDK 8 first, for example:" >&2
    echo "  brew install --cask dotnet-sdk" >&2
    exit 1
  fi

  if ! command -v swiftc >/dev/null 2>&1; then
    echo "Missing required command: swiftc" >&2
    echo >&2
    echo "Install Xcode Command Line Tools first:" >&2
    echo "  xcode-select --install" >&2
    exit 1
  fi
}

function refresh_bridge_app_bundle() {
  local bridge_app="$1"
  if [ ! -d "$bridge_app" ]; then
    echo "Bridge app bundle not found: $bridge_app" >&2
    exit 1
  fi

  cp "$BRIDGE_DIR/app_bundle/Info.plist" "$bridge_app/Contents/Info.plist"
  cp "$BRIDGE_DIR/app_bundle/BLETcpBridge" "$bridge_app/Contents/MacOS/BLETcpBridge"
  cp "$BRIDGE_DIR/app_bundle/run_bridge.command" "$bridge_app/Contents/Resources/bridge/run_bridge.command"

  chmod +x \
    "$bridge_app/Contents/MacOS/BLETcpBridge" \
    "$bridge_app/Contents/Resources/bridge/run_bridge.command"
}

function signing_enabled() {
  [ -n "$CODESIGN_IDENTITY" ]
}

function selected_codesign_identity() {
  if signing_enabled; then
    printf '%s\n' "$CODESIGN_IDENTITY"
  else
    printf '%s\n' "-"
  fi
}

function is_developer_id_identity() {
  [[ "$CODESIGN_IDENTITY" == Developer\ ID\ Application:* ]]
}

function ensure_signing_identity() {
  if ! signing_enabled; then
    return
  fi

  ensure_command security
  ensure_command codesign

  if ! security find-identity -v -p codesigning | grep -Fq "$CODESIGN_IDENTITY"; then
    echo "Signing identity not found in keychain:" >&2
    echo "  $CODESIGN_IDENTITY" >&2
    echo >&2
    echo "Available signing identities:" >&2
    security find-identity -v -p codesigning || true
    exit 1
  fi

  if [ -n "$NOTARY_PROFILE" ]; then
    ensure_command xcrun
    if ! is_developer_id_identity; then
      echo "Notarization requires a Developer ID Application identity." >&2
      exit 1
    fi
  fi
}

function run_codesign() {
  local target="$1"
  shift || true

  local sign_identity
  sign_identity="$(selected_codesign_identity)"

  local args=(codesign --force --sign "$sign_identity")
  if signing_enabled && [ -n "$CODESIGN_KEYCHAIN" ]; then
    args+=(--keychain "$CODESIGN_KEYCHAIN")
  fi
  if signing_enabled && is_developer_id_identity; then
    args+=(--options runtime --timestamp)
  fi
  if [ "$#" -gt 0 ]; then
    args+=("$@")
  fi

  local stderr_log
  stderr_log="$(mktemp "${TMPDIR:-/tmp}/codesign-stderr.XXXXXX")"
  if "${args[@]}" "$target" 2>"$stderr_log"; then
    rm -f "$stderr_log"
    return 0
  fi

  if signing_enabled && is_developer_id_identity && grep -Fq "timestamp service is not available" "$stderr_log"; then
    echo "Warning: Apple timestamp service unavailable, retrying codesign without timestamp: $target" >&2
    local retry_args=(codesign --force --sign "$sign_identity" --options runtime)
    if [ -n "$CODESIGN_KEYCHAIN" ]; then
      retry_args+=(--keychain "$CODESIGN_KEYCHAIN")
    fi
    if [ "$#" -gt 0 ]; then
      retry_args+=("$@")
    fi
    "${retry_args[@]}" "$target"
    rm -f "$stderr_log"
    return 0
  fi

  cat "$stderr_log" >&2
  rm -f "$stderr_log"
  return 1
}

function sign_capswriter_runtime() {
  local app_path="$1"
  local capswriter_dir="$app_path/Contents/Resources/capswriter"
  local runtime_root="$capswriter_dir/.python-runtime"
  local python_app="$runtime_root/Python.framework/Versions/$PYTHON_VERSION_TAG/Resources/Python.app"
  local python_framework="$runtime_root/Python.framework"

  if [ ! -d "$capswriter_dir" ]; then
    return
  fi

  if signing_enabled; then
    log_step "Signing embedded CapsWriter runtime with: $CODESIGN_IDENTITY"
  else
    log_step "Re-signing embedded CapsWriter runtime with ad-hoc signature"
  fi

  local candidate
  while IFS= read -r -d '' candidate; do
    if file -b "$candidate" 2>/dev/null | grep -q 'Mach-O'; then
      run_codesign "$candidate"
    fi
  done < <(
    find "$capswriter_dir" -type f \( -perm -111 -o -name '*.so' -o -name '*.dylib' \) -print0 2>/dev/null | sort -z
  )

  while IFS= read -r -d '' framework_dir; do
    run_codesign "$framework_dir" --deep --preserve-metadata=identifier,entitlements,flags
  done < <(find "$capswriter_dir" -type d -name 'Python.framework' -print0 2>/dev/null | sort -z)

  if [ -d "$python_app" ]; then
    if [ -f "$RUNTIME_ENTITLEMENTS_FILE" ] && signing_enabled && is_developer_id_identity; then
      run_codesign "$python_app" --deep --entitlements "$RUNTIME_ENTITLEMENTS_FILE"
    else
      run_codesign "$python_app" --deep --preserve-metadata=identifier,entitlements,flags
    fi
  fi
  if [ -d "$python_framework" ]; then
    if [ -f "$RUNTIME_ENTITLEMENTS_FILE" ] && signing_enabled && is_developer_id_identity; then
      run_codesign "$python_framework" --deep --entitlements "$RUNTIME_ENTITLEMENTS_FILE"
    else
      run_codesign "$python_framework" --deep --preserve-metadata=identifier,entitlements,flags
    fi
  fi
}

function sign_release_app() {
  local app_path="$1"

  if signing_enabled; then
    log_step "Signing nested helper apps with: $CODESIGN_IDENTITY"
  else
    log_step "Re-signing nested helper apps with ad-hoc signature"
  fi

  local helper_app
  while IFS= read -r -d '' helper_app; do
    run_codesign "$helper_app" --deep --preserve-metadata=identifier,entitlements,flags
  done < <(find "$app_path/Contents/Resources/bundled_apps" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print0 2>/dev/null | sort -z)

  sign_capswriter_runtime "$app_path"

  if signing_enabled; then
    log_step "Signing main app bundle with: $CODESIGN_IDENTITY"
  else
    log_step "Re-signing main app bundle with ad-hoc signature"
  fi
  if [ -f "$RUNTIME_ENTITLEMENTS_FILE" ] && signing_enabled && is_developer_id_identity; then
    run_codesign "$app_path" --deep --entitlements "$RUNTIME_ENTITLEMENTS_FILE"
  else
    run_codesign "$app_path" --deep --preserve-metadata=identifier,entitlements,flags
  fi

  log_step "Verifying signed app bundle"
  codesign --verify --deep --strict --verbose=2 "$app_path"
  codesign -d -r- "$app_path" 2>&1 | sed -n '1,2p'
}

function sign_release_dmg() {
  local dmg_path="$1"
  if ! signing_enabled; then
    return
  fi

  log_step "Signing release dmg"
  run_codesign "$dmg_path"
  codesign --verify --verbose=2 "$dmg_path"
}

function notarize_release_artifact() {
  local artifact_path="$1"
  if [ -z "$NOTARY_PROFILE" ]; then
    return
  fi

  log_step "Submitting $(basename "$artifact_path") for notarization"
  xcrun notarytool submit "$artifact_path" --keychain-profile "$NOTARY_PROFILE" --wait

  log_step "Stapling notarization ticket"
  xcrun stapler staple "$artifact_path"
  xcrun stapler validate "$artifact_path"
}

function create_dmg_background() {
  local output_path="$1"
  mkdir -p "$(dirname "$output_path")"
  "$PYTHON_BIN" "$DMG_BACKGROUND_SCRIPT" "$output_path" "$APP_DISPLAY_NAME"
}

function write_dmg_install_guide() {
  local output_path="$1"
  cat >"$output_path" <<EOF
安装说明

1. 将“$APP_BUNDLE_NAME”拖到“Applications”文件夹。
2. 前往“应用程序”打开 $APP_DISPLAY_NAME。
3. 首次打开如被拦截，请右键应用并选择“打开”，或到“系统设置 -> 隐私与安全性”中点击“仍要打开”。
4. 语音输入首次使用时：
   - 麦克风权限可直接在系统弹窗中点“允许”
   - 输入监控、辅助功能请按应用内引导手动开启
5. 手动开启输入监控和辅助功能后，请彻底关闭并重新打开 $APP_DISPLAY_NAME。
EOF
}

function create_release_dmg() {
  local dmg_root="$1"
  local dmg_path="$2"
  rm -f "$dmg_path"
  hdiutil create \
    -volname "$APP_DISPLAY_NAME" \
    -srcfolder "$dmg_root" \
    -ov \
    -format UDZO \
    "$dmg_path" >/dev/null
}

if ! PYTHON_BIN="$(choose_python)"; then
  cat <<EOF >&2
No supported Python interpreter was found.

PySide6 currently needs Python 3.10 / 3.11 / 3.12 / 3.13.
Please install one of them first, for example:
  brew install python@3.13

Then rerun the build, or specify it explicitly:
  PYTHON_BIN=python3.13 ./build_macos.sh
EOF
  exit 1
fi

ensure_command "$PYTHON_BIN"
PYTHON_BIN="$(ensure_venv "$PYTHON_BIN")"
if [ -z "$APP_VERSION" ]; then
  APP_VERSION="$(resolve_app_version "$PYTHON_BIN")"
fi
export APP_VERSION
PYTHON_BASE_PREFIX="$("$PYTHON_BIN" - <<'PY'
import sys
print(sys.base_prefix)
PY
)"
PYTHON_VERSION_TAG="$("$PYTHON_BIN" - <<'PY'
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}")
PY
)"
export PYTHON_BASE_PREFIX PYTHON_VERSION_TAG
ensure_signing_identity
log_step "Using Python: $("$PYTHON_BIN" --version 2>&1)"
log_step "Release version: $APP_VERSION"
if signing_enabled; then
  log_step "Stable signing identity: $CODESIGN_IDENTITY"
else
  log_step "Stable signing: disabled (no CODESIGN_IDENTITY configured)"
fi
log_step "Installing build dependencies"
"$PYTHON_BIN" -m pip install --disable-pip-version-check pip pyinstaller
"$PYTHON_BIN" -m pip install --disable-pip-version-check -r "$CONFIG_TOOL_DIR/requirements.txt"
"$PYTHON_BIN" -m pip install --disable-pip-version-check -r "$CONFIG_TOOL_DIR/capswriter/requirements-mac.txt"

log_step "Preparing macOS app icon"
if ! "$PYTHON_BIN" "$ICON_SCRIPT"; then
  if [ -f "$ICON_TARGET" ]; then
    echo "Warning: icon generation failed, reusing existing icon: $ICON_TARGET" >&2
  else
    echo "Icon generation failed and no fallback icon exists: $ICON_TARGET" >&2
    exit 1
  fi
fi

prepare_capswriter_swift_helpers

log_step "Building KeyboardConfig.app"
build_pyinstaller_app "$CONFIG_TOOL_DIR" "KeyboardConfig.mac.spec"
MAIN_APP="$CONFIG_TOOL_DIR/dist/$APP_BUNDLE_NAME"

log_step "Building hook_install.app"
build_pyinstaller_app "$HOOK_DIR" "hook_install.mac.spec"

ensure_bridge_app
refresh_bridge_app_bundle "$BRIDGE_DIR/dist/BLETcpBridge.app"

log_step "Embedding support tools into $APP_DISPLAY_NAME.app"
SUPPORT_DIR="$MAIN_APP/Contents/Resources/bundled_apps"
CAPSWRITER_DIR="$MAIN_APP/Contents/Resources/capswriter"
rm -rf "$SUPPORT_DIR" "$CAPSWRITER_DIR"
mkdir -p "$SUPPORT_DIR"
copy_app "$HOOK_DIR/dist/hook_install.app" "$SUPPORT_DIR"
copy_app "$BRIDGE_DIR/dist/BLETcpBridge.app" "$SUPPORT_DIR"
copy_capswriter_runtime "$CONFIG_TOOL_DIR/capswriter" "$CAPSWRITER_DIR"

log_step "Preparing macOS drag-and-drop bundle"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR" "$RELEASE_DIR"
copy_app "$MAIN_APP" "$DIST_DIR"
DIST_APP="$DIST_DIR/$APP_BUNDLE_NAME"
sign_release_app "$DIST_APP"

ZIP_PATH="$RELEASE_DIR/VibecodingKeyboard-macOS-${APP_VERSION}.zip"
DMG_PATH="$RELEASE_DIR/VibecodingKeyboard-macOS-${APP_VERSION}.dmg"
rm -f "$ZIP_PATH" "$DMG_PATH"

if [ "$SKIP_DMG" = "1" ]; then
  log_step "Skipping dmg creation because SKIP_DMG=1"
elif command -v hdiutil >/dev/null 2>&1; then
  log_step "Creating release dmg"
  DMG_ROOT="$DIST_DIR/dmg-root"
  rm -rf "$DMG_ROOT"
  mkdir -p "$DMG_ROOT"
  copy_app "$DIST_APP" "$DMG_ROOT"
  ln -s /Applications "$DMG_ROOT/Applications"
  write_dmg_install_guide "$DMG_ROOT/安装说明.txt"
  create_release_dmg "$DMG_ROOT" "$DMG_PATH"
  sign_release_dmg "$DMG_PATH"
else
  log_step "Skipping dmg creation because hdiutil is unavailable"
fi

log_step "Creating release zip"
ditto -c -k --sequesterRsrc --keepParent \
  "$DIST_APP" \
  "$ZIP_PATH"

if [ -n "$NOTARY_PROFILE" ]; then
  case "$NOTARIZE_TARGET" in
    dmg)
      if [ -f "$DMG_PATH" ]; then
        notarize_release_artifact "$DMG_PATH"
      else
        echo "Cannot notarize dmg because the dmg was not created." >&2
        exit 1
      fi
      ;;
    zip)
      notarize_release_artifact "$ZIP_PATH"
      ;;
    *)
      echo "Unsupported NOTARIZE_TARGET: $NOTARIZE_TARGET (expected: dmg or zip)" >&2
      exit 1
      ;;
  esac
fi

cat <<EOF

Build finished.

Apps:
  $DIST_APP

Release files:
  $ZIP_PATH
  $DMG_PATH

EOF
