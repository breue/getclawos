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

# ── Merge the new code into INSTALL_DIR (don't wipe it) ──
# Historically this block did `rm -rf $INSTALL_DIR && mv new $INSTALL_DIR`.
# That was fine when ~/.clawos held only the Rails source code. But
# starting with v3.5.0 the Mac app extracts bundled runtime/,
# openclaw-runtime/, openclaw/ into ~/.clawos BEFORE install.sh runs.
# The rm -rf then either:
#   (a) nuked the bundled runtimes (broken next launch), or
#   (b) failed with "Directory not empty" because codesign-written
#       xattrs on runtime Mach-Os prevented deletion
# — both modes seen on the zac@ 26.4 Mac during the v3.5/v3.6 launch.
#
# New strategy: rsync the new code IN ON TOP, no deletion step. The
# runtimes stay where the Mac app put them; rsync overwrites any
# Rails source file that changed. Merge-semantics mean we don't need
# the old preserve/restore dance either — storage/ .clawos.env
# .bundle/ vendor/bundle are all untouched because they aren't in
# the new source tarball.
#
# Stale-file caveat: if we rename/remove a Rails file between
# releases, it'll linger on upgrade. That's a minor flaw traded for
# robustness. Can be swept with a `git ls-files`-style manifest later.
mkdir -p "$INSTALL_DIR"
if command -v rsync >/dev/null 2>&1; then
  rsync -a "$EXTRACTED_ROOT/" "$INSTALL_DIR/"
else
  # Fallback for rare envs without rsync — pipe through tar.
  (cd "$EXTRACTED_ROOT" && tar -cf - .) | (cd "$INSTALL_DIR" && tar -xf -)
fi

# v3.7.7 — clear Rails caches after rsync so the new source isn't
# masked by stale compiled bytecode and asset bundles.
#   - tmp/cache/bootsnap/: bootsnap's on-disk cache of compiled Ruby
#     bytecode. If Ruby source files change but bootsnap sees a cache
#     hit by path, it serves OLD bytecode. Users ended up running
#     3.6.8 Rails code while new files sat on disk untouched.
#   - tmp/cache/assets/: Sprockets' compiled asset digests for JS/CSS.
#     Stale entries serve old play_controller.js after code updates,
#     which is exactly why zach@'s dashboard clicks/chat stopped
#     working on v3.7.6 — Rails was serving the v3.6.8 bundle.
#   - public/assets/: precompiled assets that the Rails server may
#     prefer over on-the-fly compilation. Wiped for same reason.
#
# These rebuild on first request, so a short slowdown on initial
# launch is the only cost. Fresh installs have nothing to clear.
echo "Clearing Rails caches so fresh source isn't masked by stale bytecode..."
rm -rf "$INSTALL_DIR/tmp/cache/bootsnap" 2>/dev/null || true
rm -rf "$INSTALL_DIR/tmp/cache/assets" 2>/dev/null || true
rm -rf "$INSTALL_DIR/public/assets" 2>/dev/null || true

# Touch tmp/restart.txt for the tmp_restart plugin — but don't rely
# on it. Belt-and-suspenders; the real fix is the hard stop below.
mkdir -p "$INSTALL_DIR/tmp"
touch "$INSTALL_DIR/tmp/restart.txt"

# HARD-STOP any running puma + all of its forked children so the
# AUTO_START block below can spawn a fresh puma with the new Rails
# source from disk. Why this is required:
#
#   1. The tmp_restart plugin's mtime check misses replaced files
#      (rsync writes a new inode; puma was watching the old one).
#   2. SIGUSR2 is also unreliable — the Ruby class reloader can keep
#      stale bytecode around for services that were `require`'d early.
#   3. Puma's solid-queue workers INHERIT the port 3200 listen socket
#      when they fork. If we only kill the puma master they keep the
#      port, the installer's respawn attempt hits EADDRINUSE, and the
#      user is stuck with a port held by worker processes that don't
#      speak HTTP — the chat then returns the "can't reach my brain"
#      fallback until the Mac app is fully quit and relaunched.
#
# Observed on v3.10.21 fresh install — this function is what prevents
# that class of bug for every future install. Silent-fail throughout
# because a cold install has nothing to kill, and that's fine.
stop_running_puma() {
  command -v lsof >/dev/null 2>&1 || return 0
  local pids deadline pid
  # `|| true` on every lsof/pipeline: the whole script runs under
  # `set -euo pipefail` and lsof exits 1 when nothing matches, which
  # would otherwise abort the installer before it even gets to the
  # restart step. These are informational checks — non-zero is fine.
  pids="$(lsof -iTCP:3200 -sTCP:LISTEN -t 2>/dev/null | sort -u || true)"
  [ -z "$pids" ] && return 0
  echo "Stopping puma + forked workers on port 3200 so new code loads..."
  for pid in $pids; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  # Up to 10s for graceful exit.
  deadline=$(( $(date +%s) + 10 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    pids="$(lsof -iTCP:3200 -sTCP:LISTEN -t 2>/dev/null | sort -u || true)"
    [ -z "$pids" ] && break
    sleep 1
  done
  # Force-kill anything still holding the port (solid-queue workers
  # often ignore SIGTERM under load).
  pids="$(lsof -iTCP:3200 -sTCP:LISTEN -t 2>/dev/null | sort -u || true)"
  for pid in $pids; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  # And sweep any orphaned solid-queue workers by command pattern,
  # in case they weren't bound to port 3200.
  pkill -TERM -f 'solid-queue' 2>/dev/null || true
  sleep 1
  pkill -KILL -f 'solid-queue' 2>/dev/null || true
  # Final check: port must be free before we let install.sh continue.
  pids="$(lsof -iTCP:3200 -sTCP:LISTEN -t 2>/dev/null | sort -u || true)"
  if [ -n "$pids" ]; then
    echo "WARNING: port 3200 still held by: $pids (install continuing, but puma restart may fail)" >&2
  fi
}
stop_running_puma

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
  echo "Starting Margin Machines web server..."

  # Spawn puma directly — NOT via `./bin/clawos start`, which goes
  # through foreman. Foreman exits (and tears down every child) as
  # soon as ANY process in Procfile.dev exits with code 0, and
  # `tailwindcss:watch` commonly finishes a one-shot pass and exits
  # cleanly on install. That was silently killing the freshly-started
  # puma right after install, leaving the user with the "can't reach
  # my brain" fallback until they quit and relaunched the Mac app.
  #
  # config/puma.rb already embeds solid_queue via `plugin :solid_queue`
  # and the Mac launcher uses this exact same command — so running
  # puma directly gives us the same topology the launcher would
  # produce, minus the foreman landmine.
  PUMA_LOG="${TMPDIR:-/tmp}/clawos-puma.log"
  (
    cd "$INSTALL_DIR"
    nohup env \
      PORT=3200 \
      RAILS_ENV=development \
      CLAWOS_ALLOW_UNREADY_START=true \
      PATH="$PATH" \
      ${GEM_PATH:+GEM_PATH="$GEM_PATH"} \
      ${GEM_HOME:+GEM_HOME="$GEM_HOME"} \
      ${BUNDLE_APP_CONFIG:+BUNDLE_APP_CONFIG="$BUNDLE_APP_CONFIG"} \
      ${BUNDLE_PATH:+BUNDLE_PATH="$BUNDLE_PATH"} \
      ${BUNDLE_DISABLE_SHARED_GEMS:+BUNDLE_DISABLE_SHARED_GEMS="$BUNDLE_DISABLE_SHARED_GEMS"} \
      bundle exec puma -C config/puma.rb \
      >"$PUMA_LOG" 2>&1 </dev/null &
    disown || true
  )

  # Wait for puma to actually accept HTTP — not just bind the port.
  # Without this check install.sh returns "installation complete"
  # before puma is serving, which hides startup failures from users.
  READY=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
           21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
    if curl -fsS -m 2 -o /dev/null http://127.0.0.1:3200/ 2>/dev/null; then
      READY=1
      break
    fi
    sleep 1
  done
  if [ "$READY" = "1" ]; then
    echo "Puma is up on http://127.0.0.1:3200"
  else
    echo "WARNING: Puma did not become ready within 40s. Check $PUMA_LOG" >&2
  fi
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
