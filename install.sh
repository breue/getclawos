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

# ── Diagnostic helpers (everything they print streams to Heroku via
# the launcher's install.log telemetry) ────────────────────────────
#
# These exist because install hangs on virgin Macs (no Xcode, no
# Homebrew, no Node/Bundler) leave us blind on the platform side: the
# install_runs row freezes at "deps_installing" with no log entries
# past the last shell echo. Every checkpoint below dumps a short,
# secret-redacted block of state so a stalled install still gives us
# enough to diagnose remotely without a back-and-forth with the user.

# Pull a tail of a file and prefix each line with "  " so it nests
# nicely inside the labeled section. Silent on missing files.
diag_tail() {
  local path="$1" lines="${2:-20}"
  if [ -r "$path" ]; then
    # `|| true` is critical here. install.sh runs under
    # `set -euo pipefail`, and `grep -v PATTERN` returns exit 1 when
    # NO lines pass through (which happens whenever the file is
    # empty — e.g., the warmup log when the gateway timed out before
    # writing anything). Without `|| true`, the empty file path
    # killed install.sh mid-diagnostic-dump and Falon's v3.10.40
    # install bombed at "Bootstrapping failed" with no useful tail.
    # See Heroku install_id 68C48322 (2026-04-28 11:48 UTC).
    tail -n "$lines" "$path" 2>/dev/null \
      | grep -vE 'ANTHROPIC_API_KEY|OPENAI_API_KEY|MM_LICENSE_KEY|^sub_[A-Za-z0-9]+' \
      | sed 's/^/  /' || true
  fi
}

diag_block_processes() {
  echo "  -- processes --"
  ps -eo pid,etime,command 2>/dev/null \
    | awk '/puma.*clawos|openclaw|ClawOSLauncher/ && !/awk/ {print "  ", $0}' \
    | head -8
}

diag_block_ports() {
  echo "  -- listen ports --"
  for port in 3200 18789; do
    pid="$(lsof -iTCP:$port -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
    if [ -n "$pid" ]; then
      echo "    $port: PID $pid"
    else
      echo "    $port: free"
    fi
  done
}

diag_block_plugins() {
  local ext="$INSTALL_DIR/openclaw/lib/node_modules/openclaw/dist/extensions"
  local nm="$INSTALL_DIR/openclaw/lib/node_modules/openclaw/node_modules"
  echo "  -- openclaw plugin state --"
  if [ -d "$nm/@anthropic-ai/sdk" ]; then
    echo "    @anthropic-ai/sdk:        present (good)"
  else
    echo "    @anthropic-ai/sdk:        MISSING — openclaw can't reach Claude"
  fi
  local stale="$(find "$ext" -maxdepth 2 -type d \
    \( -name '.openclaw-install-stage' -o -name '.openclaw-runtime-deps-copy-*' \) \
    2>/dev/null | wc -l | tr -d ' ')"
  echo "    stale staging dirs:       $stale"
  local node_count=0
  if [ -d "$ext" ]; then
    node_count="$(ls "$ext" 2>/dev/null | wc -l | tr -d ' ')"
  fi
  echo "    extensions visible:       $node_count"
}

diag_block_xattrs() {
  local sample="$INSTALL_DIR/openclaw/lib/node_modules/openclaw/node_modules/@mariozechner/clipboard-darwin-universal/clipboard.darwin-universal.node"
  if [ -f "$sample" ]; then
    local x="$(xattr -l "$sample" 2>/dev/null | head -1 || true)"
    echo "  -- quarantine xattrs --"
    if [ -z "$x" ]; then
      echo "    sample .node:             clean"
    else
      echo "    sample .node:             STILL QUARANTINED — Gatekeeper will block"
      echo "    detail:                   $x"
    fi
  fi
}

diag_block_recent_turns() {
  local db="$INSTALL_DIR/storage/development.sqlite3"
  if [ -r "$db" ] && command -v sqlite3 >/dev/null 2>&1; then
    echo "  -- recent openclaw_turns --"
    sqlite3 "$db" "SELECT id, datetime(created_at,'localtime'), agent_name, outcome, duration_ms, response_chars FROM openclaw_turns ORDER BY id DESC LIMIT 5" 2>/dev/null \
      | sed 's/^/    /' || true
  fi
}

# Print a labeled diagnostic checkpoint. Caller chooses which sub-blocks
# matter at this point in the install. Each block silently no-ops when
# the underlying state isn't there yet (e.g. plugins before extraction).
emit_diag_checkpoint() {
  local label="$1"; shift
  echo
  echo "── DIAG [$label] ──"
  for block in "$@"; do
    case "$block" in
      processes)    diag_block_processes ;;
      ports)        diag_block_ports ;;
      plugins)      diag_block_plugins ;;
      xattrs)       diag_block_xattrs ;;
      turns)        diag_block_recent_turns ;;
      gateway-log)  echo "  -- gateway.log tail --"
                    diag_tail "$INSTALL_DIR/logs/gateway.log" 25 ;;
      rails-log)    echo "  -- rails dev.log tail --"
                    diag_tail "$INSTALL_DIR/log/development.log" 25 ;;
      warmup-log)   echo "  -- warmup log tail --"
                    diag_tail "${TMPDIR:-/tmp}/clawos-openclaw-warmup.log" 25 ;;
      puma-log)     echo "  -- puma boot log tail --"
                    diag_tail "${TMPDIR:-/tmp}/clawos-puma.log" 25 ;;
      disk)         echo "  -- disk --"
                    df -h "$INSTALL_DIR" 2>/dev/null | tail -1 | sed 's/^/  /' ;;
      net)          echo "  -- network --"
                    curl -sS -o /dev/null -w "    github.com:        HTTP=%{http_code} time=%{time_total}s\n" -m 5 https://github.com 2>&1 || true
                    curl -sS -o /dev/null -w "    api.anthropic.com: HTTP=%{http_code} time=%{time_total}s\n" -m 5 https://api.anthropic.com 2>&1 || true ;;
    esac
  done
  echo "── END DIAG [$label] ──"
}
# ── End diagnostic helpers ─────────────────────────────────────────

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

# Strip macOS quarantine xattrs from the freshly-extracted openclaw
# tree. Native node addons (`*.node`: clipboard, sharp, koffi,
# pty.node, etc.) inherit `com.apple.quarantine` from the Chrome /
# Safari download path of the DMG; when openclaw tries to `dlopen`
# them the kernel raises a Gatekeeper alert ("clipboard.darwin-
# universal.node Not Opened") and the plugin load fails. Stripping
# the xattr lets dlopen succeed.
#
# We only sweep the openclaw and openclaw-runtime trees — those are
# what we just unpacked from the DMG and what contains the .node
# addons. Don't touch ~/.clawos/runtime (Ruby gems already work, and
# the gem files are owned by the codesigning user with permission
# bits that block `xattr` writes).
echo "Stripping macOS quarantine xattrs from openclaw runtime..."
if command -v xattr >/dev/null 2>&1; then
  for d in "$INSTALL_DIR/openclaw" "$INSTALL_DIR/openclaw-runtime"; do
    [ -d "$d" ] && xattr -cr "$d" 2>/dev/null || true
  done
fi

# Diagnostic snapshot right after extraction + xattr strip. If a user's
# install hangs further down, the platform record at least has a clear
# baseline of what landed on disk.
emit_diag_checkpoint "post-extract" plugins xattrs disk

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

# v3.10.32 — pin openclaw to the bundled binary on PATH BEFORE invoking
# install_local. Without this, a user who has Homebrew's openclaw on PATH
# (`/opt/homebrew/bin/openclaw`) gets that older version used by:
#   - scripts/lib/openclaw_bootstrap.sh ensure_openclaw_cli (PATH lookup)
#   - scripts/lib/openclaw_bootstrap.sh ensure_openclaw_gateway (PATH lookup
#     for `openclaw gateway start`)
#   - scripts/setup_wizard's `openclaw onboard --auth-choice anthropic-api-key`
# Then later, install.sh's own bundled `openclaw gateway start` no-ops because
# the Homebrew gateway is already running on 18789. Rails ends up calling
# the bundled CLI v2026.4.25 against the older Homebrew gateway, the CLI
# sends `cleanupBundleMcpOnRunEnd` which the older gateway rejects with
# `INVALID_REQUEST: invalid agent params`, and chat returns "Could not
# process message". Heroku install_id A79174EC was the first time we caught
# this in the wild — previously it was masked by the v3.10.30 model-pin bug.
#
# Also kill any pre-existing openclaw-gateway on 18789 so an old gateway
# from a prior install (Homebrew or otherwise) can't survive into ours.
BUNDLED_OPENCLAW_BIN="$INSTALL_DIR/openclaw/bin"
if [ -x "$BUNDLED_OPENCLAW_BIN/openclaw" ]; then
  export PATH="$BUNDLED_OPENCLAW_BIN:$PATH"
  echo "  Pinned openclaw CLI to bundled $BUNDLED_OPENCLAW_BIN/openclaw"
  # v3.10.34 — only kill an existing gateway on 18789 if it's NOT
  # the bundled one. v3.10.32 killed unconditionally, which on a
  # normal install path SIGKILL'd the bundled gateway the launcher
  # had just started (Heroku install_id A42DB77D — install.sh killed
  # the launcher's bundled gateway, then install_local tried to
  # restart it via the wrong CLI [Homebrew, due to PATH bug A]).
  # The previous gateway then either failed to come back or came
  # back as the wrong version, warmup timed out at 300s, install
  # bombed at the bootstrap step.
  #
  # Surgical ownership detection. The gateway process renames its argv
  # to just "openclaw-gateway" (no path), so `ps args=` is useless for
  # telling whose gateway it is. Instead, read the loaded `node` binary
  # via `lsof -p PID` (the `txt` entries list executable images and
  # mapped libraries). If node lives under $INSTALL_DIR/, the launcher
  # spawned it with our bundled openclaw-runtime — leave it alone. If
  # it's anywhere else (Homebrew, nvm, global npm), kill it so the
  # bundled CLI's gateway-start can take over with a known version.
  if command -v lsof >/dev/null 2>&1; then
    OLD_GW_PIDS="$(lsof -iTCP:18789 -sTCP:LISTEN -t 2>/dev/null | sort -u | tr '\n' ' ' || true)"
    if [ -n "$OLD_GW_PIDS" ]; then
      # v3.10.36 — read the bundled openclaw.mjs's mtime ONCE, before
      # the loop. We compare each gateway PID's start time against this:
      # a PID that started before mjs mtime is running pre-extraction
      # code, even when its node binary still lives under $INSTALL_DIR.
      # That's the bug we kept tripping on: an "ours" gateway from a
      # PREVIOUS MM install survived the upgrade, the v3.10.34 ownership
      # check left it alone, and Rails ended up talking to old code that
      # didn't recognize the new agent params.
      BUNDLED_MJS="$INSTALL_DIR/openclaw/lib/node_modules/openclaw/openclaw.mjs"
      MJS_MTIME=""
      if [ -f "$BUNDLED_MJS" ]; then
        MJS_MTIME="$(stat -f %m "$BUNDLED_MJS" 2>/dev/null || true)"
      fi

      KILL_PIDS=""
      for pid in $OLD_GW_PIDS; do
        node_path="$(lsof -p "$pid" 2>/dev/null | awk '$4 == "txt" && $NF ~ /\/node$/ {print $NF; exit}')"
        # Prefix-strip $INSTALL_DIR/. If $node_path started with it,
        # the strip changes the value; if it didn't, the value stays
        # the same. This is POSIX-clean and handles paths with spaces.
        is_bundled_path=0
        if [ -n "$node_path" ] && [ "${node_path#$INSTALL_DIR/}" != "$node_path" ]; then
          is_bundled_path=1
        fi

        is_stale=0
        if [ "$is_bundled_path" = "1" ] && [ -n "$MJS_MTIME" ]; then
          gw_lstart="$(ps -o lstart= -p "$pid" 2>/dev/null || true)"
          gw_start_epoch=""
          if [ -n "$gw_lstart" ]; then
            gw_start_epoch="$(date -j -f "%a %b %e %T %Y" "$gw_lstart" "+%s" 2>/dev/null || true)"
          fi
          if [ -n "$gw_start_epoch" ] && [ "$gw_start_epoch" -lt "$((MJS_MTIME - 60))" ]; then
            is_stale=1
          fi
        fi

        if [ "$is_bundled_path" = "1" ] && [ "$is_stale" = "0" ]; then
          echo "  Bundled gateway already running on 18789 (pid $pid, node=$node_path) — leaving it"
        elif [ "$is_bundled_path" = "1" ] && [ "$is_stale" = "1" ]; then
          echo "  Bundled but STALE gateway on 18789 (pid $pid started before openclaw.mjs was extracted) — replacing"
          KILL_PIDS="$KILL_PIDS $pid"
        else
          KILL_PIDS="$KILL_PIDS $pid"
        fi
      done
      if [ -n "$KILL_PIDS" ]; then
        echo "  Killing gateway on 18789:$KILL_PIDS"
        kill -TERM $KILL_PIDS 2>/dev/null || true
        sleep 1
        kill -KILL $KILL_PIDS 2>/dev/null || true
      fi
    fi
  fi
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

# Pre-warm openclaw in the background. The FIRST `openclaw agent --local`
# invocation installs bundled runtime deps for all 18 plugins (acpx,
# amazon-bedrock, anthropic, browser, …) which takes ~60s on a cold
# Mac. If we don't do this here, the user's first chat turn hits that
# plugin-install window, overruns InlineRunner's 45s timeout, and
# returns "Hmm, I'm not able to reach my brain right now".
#
# Fire-and-forget: the install.sh doesn't wait for warmup to finish.
# By the time the user clicks into Chief chat, plugins are cached and
# turns complete in ~10s.
OPENCLAW_BIN="$INSTALL_DIR/openclaw/bin/openclaw"
OPENCLAW_RUNTIME_BIN="$INSTALL_DIR/openclaw-runtime/bin"
EXT_DIR="$INSTALL_DIR/openclaw/lib/node_modules/openclaw/dist/extensions"
if [ -x "$OPENCLAW_BIN" ] && [ -d "$OPENCLAW_RUNTIME_BIN" ]; then
  # Wipe leftover plugin-install staging artifacts before we kick off
  # warmup. openclaw's plugin installer uses npm's atomic-rename
  # pattern: stages deps into `<plugin>/.openclaw-install-stage/
  # node_modules`, then renames into `<plugin>/node_modules`. If a
  # previous install was interrupted (SIGKILL from InlineRunner's 45s
  # timeout, app force-quit, sleep, etc.) the staging dir is left on
  # disk in a half-written state. The NEXT install hits ENOTEMPTY on
  # rename/rmdir, npm bails, openclaw's `loadOpenClawPlugins` raises
  # `PluginLoadFailureError: plugin load failed: anthropic`, and the
  # CLI exits before serving any chat turn. Every subsequent user
  # message returns "can't reach my brain" until the staging dirs are
  # cleared by hand.
  #
  # Observed on user upgrade across v3.10.21 → .22 → .23 — partial
  # plugin state from the v3.10.21 install (which timed out before
  # finishing) blocked all later installs. Sweep these every install
  # so plugin install always starts from a clean slate.
  if [ -d "$EXT_DIR" ]; then
    find "$EXT_DIR" -maxdepth 2 -type d \
      \( -name ".openclaw-install-stage" -o -name ".openclaw-runtime-deps-copy-*" \) \
      -exec rm -rf {} + 2>/dev/null || true
  fi

  # v3.10.37 — strip stale agents.defaults keys from openclaw.json
  # before any `openclaw gateway` invocation. openclaw 2026.4.25
  # rejects `contextInjection`, `experimental`, and `startupContext`
  # under agents.defaults (Unrecognized keys), and `gateway run`
  # exits before binding even with --allow-unconfigured. Earlier
  # openclaw versions wrote those keys during onboarding, so any
  # user upgrading from openclaw <2026.4.x has a poisoned config
  # that blocks gateway start. The error message tells the user to
  # run `openclaw doctor --fix`, but doctor empirically does not
  # strip these keys (verified against 2026.4.25 — it covers other
  # repairs only). Heroku install_ids ADB2339A + 33F971F8 both
  # bombed at the bootstrap step waiting for a gateway that could
  # never start. Fix: surgical strip via a tiny inline Ruby pass.
  PROFILE_CONFIG="$HOME/.openclaw-margin-machines/openclaw.json"
  RUBY_BIN="$INSTALL_DIR/runtime/bin/ruby"
  if [ -f "$PROFILE_CONFIG" ] && [ -x "$RUBY_BIN" ]; then
    "$RUBY_BIN" -rjson -e '
      path = ARGV[0]
      cfg = JSON.parse(File.read(path)) rescue nil
      exit 0 unless cfg.is_a?(Hash)
      defaults = cfg.dig("agents", "defaults")
      exit 0 unless defaults.is_a?(Hash)
      stripped = []
      %w[contextInjection experimental startupContext].each do |k|
        stripped << k if defaults.delete(k)
      end
      exit 0 if stripped.empty?
      File.write(path, JSON.pretty_generate(cfg))
      warn "  Stripped openclaw config keys rejected by 2026.4.x schema: #{stripped.join(", ")}."
    ' "$PROFILE_CONFIG" || true
  fi

  # Make sure the openclaw-gateway service is running before warmup.
  # The Mac launcher normally starts it, but install.sh can run before
  # the launcher's gateway is up (or after we just restarted puma).
  # `gateway start` is idempotent — it no-ops if a service is already
  # running on the bind port.
  # v3.10.35 — `--profile margin-machines` isolates state under
  # ~/.openclaw-margin-machines/ so no pre-existing user openclaw
  # state pollutes our gateway. See LauncherModel.openclawProfile
  # for the full rationale.
  echo "Ensuring openclaw gateway is running..."
  PATH="$OPENCLAW_RUNTIME_BIN:$PATH" \
    "$OPENCLAW_BIN" --profile margin-machines gateway start >/dev/null 2>&1 || true
  # Brief wait for the gateway to bind its port. 18789 is the default.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -n "$(lsof -iTCP:18789 -sTCP:LISTEN -t 2>/dev/null || true)" ]; then break; fi
    sleep 1
  done

  # Diagnostic snapshot before warmup so we know what state the user's
  # machine was in when warmup either succeeded or stalled.
  emit_diag_checkpoint "pre-warmup" plugins ports processes

  # Warmup turn through the GATEWAY (not `--local`). The gateway is
  # already loaded — turns finish in ~10–12s. Switching to `--local`
  # for warmup, as we did before, took 60–180s on openclaw 2026.4.24+
  # because every `agent --local` invocation re-spawns node and
  # re-loads ALL 76 plugins from disk. Through the gateway, plugins
  # are loaded once at gateway start and reused per turn.
  #
  # Block synchronously with a 60s deadline so install.sh exits only
  # when chat is actually serviceable. If warmup somehow fails we
  # warn but proceed — the user can retry; we shouldn't ever hang
  # the installer indefinitely on a flaky openclaw.
  echo "Warming up openclaw via gateway..."
  WARMUP_LOG="${TMPDIR:-/tmp}/clawos-openclaw-warmup.log"
  # v3.10.42 — bumped 60s → 180s. On bare machines (no Homebrew/Xcode/
  # Node prior installed), the gateway's first run stages 9 npm runtime
  # deps for plugins (playwright-core, @modelcontextprotocol/sdk,
  # @homebridge/ciao, etc.) plus loads channels and sidecars. Local
  # timing on a warm machine: gateway responds to /health in 40–44s.
  # On Falon's bare macOS 15.7.4 install (Heroku 68C48322), the
  # warmup never produced output before the 60s deadline, the warmup
  # log was empty, and install.sh's diag_tail crashed under set -euo
  # pipefail (separately fixed). 180s gives ~3× headroom and is still
  # a reasonable wait for a one-time install step.
  WARMUP_DEADLINE_SECONDS=180
  (
    PATH="$OPENCLAW_RUNTIME_BIN:$PATH" \
    "$OPENCLAW_BIN" --profile margin-machines agent --agent main \
      --session-id "mm-warmup-$$" \
      --message "ping" \
      --timeout 60 \
      --json \
      >"$WARMUP_LOG" 2>&1 </dev/null &
  ) &

  # Gateway responses end with `"summary": "completed"` at the top
  # level when the turn finishes successfully. The older `--local`
  # path emits `"finalAssistantVisibleText"` instead — match either
  # so this works no matter which code path the warmup ends up on.
  WARMUP_OK=0
  for s in $(seq 1 "$WARMUP_DEADLINE_SECONDS"); do
    if [ -s "$WARMUP_LOG" ] && grep -qE '"summary"[[:space:]]*:[[:space:]]*"completed"|"finalAssistantVisibleText"' "$WARMUP_LOG" 2>/dev/null; then
      WARMUP_OK=1
      echo "openclaw is ready after ${s}s."
      break
    fi
    if grep -q 'PluginLoadFailureError\|Failed to start CLI' "$WARMUP_LOG" 2>/dev/null; then
      echo "WARNING: openclaw plugin load reported failure. Tail of $WARMUP_LOG:" >&2
      tail -20 "$WARMUP_LOG" >&2 || true
      break
    fi
    sleep 1
  done

  if [ "$WARMUP_OK" != "1" ]; then
    echo "WARNING: openclaw warmup did not finish within ${WARMUP_DEADLINE_SECONDS}s." >&2
    echo "         The first chat may take longer than usual; check $WARMUP_LOG" >&2
    # Failure path needs more diagnostics, including log tails, since
    # we'll otherwise be diagnosing this from Heroku with nothing else.
    emit_diag_checkpoint "warmup-failed" warmup-log gateway-log puma-log processes ports plugins net
  else
    emit_diag_checkpoint "warmup-ok" warmup-log turns
  fi
fi

# End-to-end chat-health probe: this is the canonical "would the user's
# next chat work?" check. We hit the same Rails endpoint the WKWebView
# UI calls, with a short timeout, and report the result. The launcher's
# end-state probe only checks `gateway_reachable: true` (HTTP probe of
# port 18789), which doesn't catch the case where the gateway is up
# but openclaw can't load a plugin, or InlineRunner can't reach the
# gateway, or Anthropic times out. This probe exercises the full path.
#
# IMPORTANT: only run when AUTO_START=true. The Mac launcher passes
# CLAWOS_AUTO_START=false and starts puma + the gateway *itself*
# AFTER install.sh exits. Running the probe inside the launcher-
# driven flow always fails with `curl: (7) Failed to connect` —
# confusing noise in the Heroku log column. Direct curl|bash users
# DO want this probe (their AUTO_START block is what just spun
# puma up, so the probe is meaningful).
if [ "$AUTO_START" = "true" ]; then
  echo
  echo "── DIAG [chat-health-probe] ──"
  CHAT_PROBE_START=$(date +%s)
  CHAT_PROBE_RESPONSE="$(curl -fsS -m 30 -X POST \
    -H 'Content-Type: application/json' \
    -d '{"message":"installer chat-health probe — please reply with one short sentence"}' \
    http://127.0.0.1:3200/play/chat 2>&1 || true)"
  CHAT_PROBE_ELAPSED=$(( $(date +%s) - CHAT_PROBE_START ))
  if echo "$CHAT_PROBE_RESPONSE" | grep -q '"ok":true' && \
     ! echo "$CHAT_PROBE_RESPONSE" | grep -q "not able to reach my brain"; then
    echo "  result:                   PASS (${CHAT_PROBE_ELAPSED}s)"
    echo "  reply (truncated):        $(echo "$CHAT_PROBE_RESPONSE" | head -c 180)"
  elif echo "$CHAT_PROBE_RESPONSE" | grep -q "not able to reach my brain"; then
    echo "  result:                   FAIL — fallback message returned (${CHAT_PROBE_ELAPSED}s)"
    echo "  reply (truncated):        $(echo "$CHAT_PROBE_RESPONSE" | head -c 180)"
  elif [ -z "$CHAT_PROBE_RESPONSE" ] || echo "$CHAT_PROBE_RESPONSE" | grep -qi 'curl.*timed out'; then
    echo "  result:                   FAIL — curl timed out at ${CHAT_PROBE_ELAPSED}s (puma or InlineRunner stalled)"
  else
    echo "  result:                   FAIL — unexpected response shape (${CHAT_PROBE_ELAPSED}s)"
    echo "  reply (truncated):        $(echo "$CHAT_PROBE_RESPONSE" | head -c 200)"
  fi
  echo "── END DIAG [chat-health-probe] ──"
fi

# Final state-of-the-world snapshot. With this, even if a future user
# reports "chat doesn't work", we can read everything we'd need from
# the Heroku installation_runs.log column without asking them to run
# anything in their terminal.
emit_diag_checkpoint "final" processes ports plugins xattrs turns warmup-log gateway-log rails-log puma-log

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
