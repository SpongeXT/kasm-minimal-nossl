#!/bin/bash
# Start QingLong panel (npm version, no Docker) inside the minimal image.
# Runs from vnc_startup.sh right after start_kasmvnc, in the background,
# as the current user (kasm-user, no sudo/root — Altare blocks privilege
# escalation with "no new privileges", and QingLong's own scheduler is
# internal Node.js, not the system cron daemon, so no root is needed).
# Access: open http://localhost:5700 in the desktop's Chrome. Altare only
# exposes port 6902 externally, so 5700 is NOT reachable from outside —
# it is only reachable from Chrome inside this same container, which is
# enough for managing tasks. First run needs init in the browser:
# open localhost:5700 and create the admin account.
# Data: QL_DATA_DIR=/data/qinglong/data (Altare /data persists across
# redeploys; /home does not). Falls back to $HOME/qinglong/data if /data
# is not writable.
#
# Pitfalls fixed 2026-11-24 (build #10 failure):
# 1. The panel's startup wrapper runs `sudo apt-get update` to install
#    system deps. Real sudo is blocked by no-new-privileges, so the panel
#    exited immediately and never listened on 5700. Fix: a local `sudo`
#    shim earlier in PATH that no-ops apt/dpkg calls (all deps are already
#    baked into the image) and runs any other command directly as the
#    current user. The shim only affects this launcher's PATH, nothing else.
# 2. The old launcher retried every 5s forever, so the log grew without
#    bound (2079 lines in one run). Fix: backoff on fast failures
#    (5s/15s/30s/60s) and rotate the log when it passes 2 MiB.
# 3. The old log in /data survives redeploy, so it starts full of the old
#    sudo failures. Fix: trim it to the last 200 lines on startup.
set -x
export HOME=/home/kasm-user
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
# --- sudo shim (fix 1) ---
SHIM_DIR="$HOME/.ql-shim"
mkdir -p "$SHIM_DIR" 2>/dev/null || true
cat > "$SHIM_DIR/sudo" <<'SHIM_EOF'
#!/bin/sh
# No-op sudo for QingLong startup: real sudo is blocked by Altare, and all
# system deps are already in the image, so package installs are skipped.
# Any other command runs directly as the current user.
case "$*" in
  *apt-get*|*apt\ update*|*apt\ install*|*dpkg*)
    echo "ql-sudo-shim: skipping sudo $*" >&2
    exit 0
    ;;
esac
exec "$@"
SHIM_EOF
chmod +x "$SHIM_DIR/sudo" 2>/dev/null || true
export PATH="$SHIM_DIR:$PATH"
# QL_DIR is where `npm install -g @whyour/qinglong` put the panel.
if [ -z "$QL_DIR" ]; then
  if command -v npm >/dev/null 2>&1; then
    QL_DIR="$(npm root -g)/@whyour/qinglong"
  fi
  [ -d "$QL_DIR" ] || QL_DIR="/usr/lib/node_modules/@whyour/qinglong"
  [ -d "$QL_DIR" ] || QL_DIR="/usr/local/lib/node_modules/@whyour/qinglong"
fi
export QL_DIR
# Data dir: prefer /data (persistent), fall back to home.
QL_DATA_DIR="/data/qinglong/data"
if ! mkdir -p "$QL_DATA_DIR" 2>/dev/null || [ ! -w "$QL_DATA_DIR" ]; then
  echo "qinglong-launcher: /data not writable, falling back to \$HOME/qinglong/data" >&2
  QL_DATA_DIR="$HOME/qinglong/data"
  mkdir -p "$QL_DATA_DIR" || { echo "qinglong-launcher: cannot create data dir" >&2; exit 1; }
fi
export QL_DATA_DIR
LOG_FILE="$QL_DATA_DIR/../qinglong.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
# Trim the stale log from the failed build (fix 3): keep last 200 lines.
if [ -f "$LOG_FILE" ]; then
  tail -n 200 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || true
fi
echo "qinglong-launcher: QL_DIR=$QL_DIR QL_DATA_DIR=$QL_DATA_DIR" >> "$LOG_FILE" 2>&1 || true
echo "qinglong-launcher: QL_DIR=$QL_DIR QL_DATA_DIR=$QL_DATA_DIR" >&2
command -v node >/dev/null 2>&1 || { echo "qinglong-launcher: node not found" >&2; exit 1; }
command -v qinglong >/dev/null 2>&1 || { echo "qinglong-launcher: qinglong command not found" >&2; exit 1; }
{ node --version; npm --version; pnpm --version; python3 --version; } >> "$LOG_FILE" 2>&1 || true
node --version >&2
# Keep it running with backoff and log rotation (fix 2).
FAIL_COUNT=0
while true; do
  if [ -f "$LOG_FILE" ]; then
    LOG_SIZE="$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)"
    if [ "$LOG_SIZE" -gt 2097152 ]; then
      tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || true
      echo "qinglong-launcher: log rotated" >> "$LOG_FILE"
    fi
  fi
  echo "qinglong-launcher: starting qinglong on :5700 (fast-fail streak $FAIL_COUNT)" >> "$LOG_FILE"
  START_TS="$(date +%s)"
  qinglong >> "$LOG_FILE" 2>&1 &
  QL_PID=$!
  # Wait up to 60s for the panel to listen, so success is visible in the log.
  for _i in $(seq 1 60); do
    if curl -fs -o /dev/null http://localhost:5700/ 2>/dev/null; then
      echo "qinglong-launcher: panel listening on :5700" >> "$LOG_FILE"
      break
    fi
    kill -0 "$QL_PID" 2>/dev/null || break
    sleep 1
  done
  wait "$QL_PID"
  EXIT_CODE=$?
  ELAPSED=$(( $(date +%s) - START_TS ))
  if [ "$ELAPSED" -lt 10 ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    FAIL_COUNT=0
  fi
  if [ "$FAIL_COUNT" -ge 5 ]; then
    SLEEP_SECS=60
  elif [ "$FAIL_COUNT" -ge 3 ]; then
    SLEEP_SECS=30
  elif [ "$FAIL_COUNT" -ge 1 ]; then
    SLEEP_SECS=15
  else
    SLEEP_SECS=5
  fi
  echo "qinglong-launcher: qinglong exited code $EXIT_CODE after ${ELAPSED}s, retry in ${SLEEP_SECS}s" >> "$LOG_FILE"
  sleep "$SLEEP_SECS"
done
