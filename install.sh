#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

sha256_of_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    echo "No SHA256 tool found (expected shasum or sha256sum)." >&2
    exit 1
  fi
}

require_cmd curl
require_cmd tar
require_cmd awk

INSTALL_DIR="${INSTALL_DIR:-$HOME/.clawos}"
RELEASE_CHANNEL="${CLAWOS_RELEASE_CHANNEL:-stable}"
MANIFEST_URL="${CLAWOS_MANIFEST_URL:-https://raw.githubusercontent.com/breue/getclawos/main/releases/${RELEASE_CHANNEL}/latest.env}"
AUTO_START="${CLAWOS_AUTO_START:-true}"
AUTO_OPEN_DASHBOARD="${CLAWOS_AUTO_OPEN_DASHBOARD:-true}"

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "Margin Machines installer"

# ── Source the bundle ──
# Two modes:
#   1. CLAWOS_LOCAL_TARBALL set → Mac app's DMG already has the source
#      tarball inside Contents/Resources/ and passed us the path. Use
#      it directly, skip manifest + download entirely. This is the
#      zero-network-calls path shipped in v3.6.0.
#   2. Otherwise → fall back to the v3.5.x flow: fetch manifest, then
#      download the release tarball from the URL it points at.
TARBALL_PATH="$WORK_DIR/clawos.tar.gz"
if [ -n "${CLAWOS_LOCAL_TARBALL:-}" ] && [ -f "$CLAWOS_LOCAL_TARBALL" ]; then
  echo "Using local source tarball: $CLAWOS_LOCAL_TARBALL"
  cp "$CLAWOS_LOCAL_TARBALL" "$TARBALL_PATH"
  # Checksum only validated if caller supplied CLAWOS_LOCAL_SHA256 —
  # the DMG is already signed + notarized so the tarball inside it is
  # covered by Apple's integrity check.
  if [ -n "${CLAWOS_LOCAL_SHA256:-}" ]; then
    ACTUAL_SHA256="$(sha256_of_file "$TARBALL_PATH")"
    if [ "$ACTUAL_SHA256" != "$CLAWOS_LOCAL_SHA256" ]; then
      echo "Local tarball checksum mismatch." >&2
      echo "Expected: $CLAWOS_LOCAL_SHA256" >&2
      echo "Actual:   $ACTUAL_SHA256" >&2
      exit 1
    fi
    echo "Checksum verified."
  fi
else
  echo "Manifest: $MANIFEST_URL"
  MANIFEST_PATH="$WORK_DIR/latest.env"
  curl -fsSL "$MANIFEST_URL" -o "$MANIFEST_PATH"

  # Only keep expected CLAWOS_* assignment lines before sourcing.
  SANITIZED_MANIFEST="$WORK_DIR/latest.sanitized.env"
  grep -E '^CLAWOS_[A-Z0-9_]+=' "$MANIFEST_PATH" > "$SANITIZED_MANIFEST"
  # shellcheck disable=SC1090
  source "$SANITIZED_MANIFEST"

  if [ -z "${CLAWOS_TARBALL_URL:-}" ] || [ -z "${CLAWOS_TARBALL_SHA256:-}" ]; then
    echo "Manifest is missing CLAWOS_TARBALL_URL or CLAWOS_TARBALL_SHA256." >&2
    exit 1
  fi

  echo "Downloading Margin Machines release bundle..."
  curl -fsSL "$CLAWOS_TARBALL_URL" -o "$TARBALL_PATH"

  ACTUAL_SHA256="$(sha256_of_file "$TARBALL_PATH")"
  if [ "$ACTUAL_SHA256" != "$CLAWOS_TARBALL_SHA256" ]; then
    echo "Checksum mismatch for downloaded bundle." >&2
    echo "Expected: $CLAWOS_TARBALL_SHA256" >&2
    echo "Actual:   $ACTUAL_SHA256" >&2
    exit 1
  fi

  echo "Checksum verified."
fi

EXTRACT_DIR="$WORK_DIR/extracted"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$TARBALL_PATH" -C "$EXTRACT_DIR"
EXTRACTED_ROOT="$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"
if [ -z "$EXTRACTED_ROOT" ]; then
  echo "Unable to locate extracted bundle directory." >&2
  exit 1
fi

if [ -e "$INSTALL_DIR" ]; then
  echo "Existing install found. Upgrading code, preserving data..."
  PRESERVE_DIR="$WORK_DIR/preserve"
  mkdir -p "$PRESERVE_DIR"
  # Preserve: database, env config, gems, and any user files
  for item in storage .clawos.env .bundle vendor/bundle; do
    if [ -e "$INSTALL_DIR/$item" ]; then
      mkdir -p "$PRESERVE_DIR/$(dirname "$item")"
      cp -a "$INSTALL_DIR/$item" "$PRESERVE_DIR/$item"
    fi
  done
  rm -rf "$INSTALL_DIR"
fi

mkdir -p "$(dirname "$INSTALL_DIR")"
mv "$EXTRACTED_ROOT" "$INSTALL_DIR"

# Restore preserved data into new install
if [ -d "${PRESERVE_DIR:-}" ]; then
  echo "Restoring user data..."
  cp -a "$PRESERVE_DIR"/. "$INSTALL_DIR/" 2>/dev/null || true
fi

cd "$INSTALL_DIR"
if [ ! -x "./bin/clawos" ]; then
  chmod +x ./bin/clawos
fi

# Prefer the Mac app's bundled runtime if it was extracted to ~/.clawos/runtime
# (present on v3.5.0+). With the bundled runtime we skip Homebrew detection
# entirely — the user shouldn't need any system deps.
MM_RUNTIME="$HOME/.clawos/runtime"
if [ -x "$MM_RUNTIME/bin/ruby" ]; then
  export MM_RUNTIME
  export PATH="$MM_RUNTIME/bin:$PATH"
  export GEM_PATH="$MM_RUNTIME/vendor/bundle/ruby/$("$MM_RUNTIME/bin/ruby" -e 'print Gem.ruby_api_version')"
  export BUNDLE_APP_CONFIG="$MM_RUNTIME/.bundle"
  export BUNDLE_PATH="$MM_RUNTIME/vendor/bundle"
  export BUNDLE_DISABLE_SHARED_GEMS=true
  echo "Using bundled Ruby runtime ($("$MM_RUNTIME/bin/ruby" -e 'print RUBY_VERSION'))"
else
  # Legacy path — Homebrew Ruby fallback for users on v3.4.x-style installs
  # or dev builds without a bundled runtime.
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
  if [ -x /opt/homebrew/opt/ruby/bin/ruby ]; then
    export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
    export GEM_HOME="$HOME/.gem/ruby/$(/opt/homebrew/opt/ruby/bin/ruby -e 'puts RUBY_VERSION' 2>/dev/null || echo '3.4.0')"
    export PATH="$GEM_HOME/bin:$PATH"
  fi
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" 2>/dev/null
fi

echo "Running Margin Machines installer..."
./bin/clawos install

if [ "$AUTO_START" = "true" ]; then
  echo "Starting Margin Machines services..."
  nohup ./bin/clawos start >"${TMPDIR:-/tmp}/clawos-start.log" 2>&1 &
fi

if [ "$AUTO_OPEN_DASHBOARD" = "true" ] && [ "$(uname -s)" = "Darwin" ] && command -v open >/dev/null 2>&1; then
  open "http://127.0.0.1:3200" || true
fi

echo
echo "Margin Machines installation complete."
echo "Install dir:"
echo "  $INSTALL_DIR"
echo "Dashboard:"
echo "  http://127.0.0.1:3200"
echo "GUI setup app:"
echo "  /Applications/MarginMachines.app (or ~/Applications/MarginMachines.app)"
