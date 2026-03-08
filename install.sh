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
MANIFEST_URL="${CLAWOS_MANIFEST_URL:-https://getclawos.com/releases/${RELEASE_CHANNEL}/latest.env}"
AUTO_START="${CLAWOS_AUTO_START:-true}"
AUTO_OPEN_DASHBOARD="${CLAWOS_AUTO_OPEN_DASHBOARD:-true}"

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "ClawOS web installer"
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

TARBALL_PATH="$WORK_DIR/clawos.tar.gz"
echo "Downloading ClawOS release bundle..."
curl -fsSL "$CLAWOS_TARBALL_URL" -o "$TARBALL_PATH"

ACTUAL_SHA256="$(sha256_of_file "$TARBALL_PATH")"
if [ "$ACTUAL_SHA256" != "$CLAWOS_TARBALL_SHA256" ]; then
  echo "Checksum mismatch for downloaded bundle." >&2
  echo "Expected: $CLAWOS_TARBALL_SHA256" >&2
  echo "Actual:   $ACTUAL_SHA256" >&2
  exit 1
fi

echo "Checksum verified."

EXTRACT_DIR="$WORK_DIR/extracted"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$TARBALL_PATH" -C "$EXTRACT_DIR"
EXTRACTED_ROOT="$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"
if [ -z "$EXTRACTED_ROOT" ]; then
  echo "Unable to locate extracted bundle directory." >&2
  exit 1
fi

if [ -e "$INSTALL_DIR" ]; then
  BACKUP_DIR="${INSTALL_DIR}.backup.$(date +%Y%m%d%H%M%S)"
  echo "Existing install found. Backing up to:"
  echo "  $BACKUP_DIR"
  mv "$INSTALL_DIR" "$BACKUP_DIR"
fi

mkdir -p "$(dirname "$INSTALL_DIR")"
mv "$EXTRACTED_ROOT" "$INSTALL_DIR"

cd "$INSTALL_DIR"
if [ ! -x "./bin/clawos" ]; then
  chmod +x ./bin/clawos
fi

echo "Running ClawOS installer..."
./bin/clawos install

if [ "$AUTO_START" = "true" ]; then
  echo "Starting ClawOS services..."
  nohup ./bin/clawos start >"${TMPDIR:-/tmp}/clawos-start.log" 2>&1 &
fi

if [ "$AUTO_OPEN_DASHBOARD" = "true" ] && [ "$(uname -s)" = "Darwin" ] && command -v open >/dev/null 2>&1; then
  open "http://127.0.0.1:3000" || true
fi

echo
echo "ClawOS installation complete."
echo "Install dir:"
echo "  $INSTALL_DIR"
echo "Dashboard:"
echo "  http://127.0.0.1:3000"
echo "GUI setup app:"
echo "  /Applications/ClawOS.app (or ~/Applications/ClawOS.app)"
