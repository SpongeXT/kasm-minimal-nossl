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
#    bound (2079 lines in one run). Fix: backoff on failures and rotate
#    the log when it passes 2 MiB.
# 3. The old log in /data survives redeploy, so it starts full of the old
#    sudo failures. Fix: trim it to the last 200 lines on startup.
# Pitfalls fixed 2026-11-24 (build #11 failure):
# 4. The startup script also requires `nginx` (it runs it before starting
#    the panel service). The image had no nginx, so it died with exit 127
#    every 14s. Fix: nginx is now baked into the image (Dockerfile), and
#    the launcher also shims `nginx` to a no-op — as kasm-user it cannot
#    bind port 80 or write /var/log/nginx, and the Node panel serves 5700
#    directly, so the nginx step only needs to pass, not actually run.
# 5. Backoff never engaged in build #11: every run took 14s, over the old
#    10s "fast failure" threshold, so the streak reset to 0 each time and
#    it retried every 5s forever. Fix: the streak now increments on every
#    non-zero exit and only resets after the panel actually listened and
#    stayed up 60s+; the threshold is 60s, not 10s.
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
# --- nginx shim (fix 4) ---
# The startup script runs nginx before the panel service, but as kasm-user
# nginx cannot bind port 80 or write its pid/log files, and the Node panel
# serves 5700 directly — so this step only needs to pass, not actually run.
# Real nginx is still baked into the image (Dockerfile) for manual use.
cat > "$SHIM_DIR/nginx" <<'NGINX_EOF'
#!/bin/sh
echo "ql-nginx-shim: skipping nginx $*" >&2
exit 0
NGINX_EOF
chmod +x "$SHIM_DIR/nginx" 2>/dev/null || true
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
  # 日志轮转（保留现有的 2 MiB 轮转逻辑）。
  if [ -f "$LOG_FILE" ]; then
    LOG_SIZE="$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)"
    if [ "$LOG_SIZE" -gt 2097152 ]; then
      tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || true
      echo "qinglong-launcher: log rotated" >> "$LOG_FILE"
    fi
  fi
  # 监控模式：面板在跑就什么都不做。
  if curl -fs -o /dev/null http://localhost:5700/ 2>/dev/null; then
    FAIL_COUNT=0
    sleep 60
    continue
  fi
  # 面板掉了：跑一次启动脚本把它拉起来。
  echo "qinglong-launcher: panel not listening, starting qinglong (fail streak $FAIL_COUNT)" >> "$LOG_FILE"
  START_TS="$(date +%s)"
  LISTENED=0
  qinglong >> "$LOG_FILE" 2>&1 &
  QL_PID=$!
  for _i in $(seq 1 60); do
    if curl -fs -o /dev/null http://localhost:5700/ 2>/dev/null; then
      echo "qinglong-launcher: panel listening on :5700" >> "$LOG_FILE"
      LISTENED=1
      break
    fi
    kill -0 "$QL_PID" 2>/dev/null || break
    sleep 1
  done
  wait "$QL_PID"
  EXIT_CODE=$?
  ELAPSED=$(( $(date +%s) - START_TS ))
  if [ "$LISTENED" -eq 1 ]; then
    FAIL_COUNT=0
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  if [ "$LISTENED" -eq 1 ]; then
    SLEEP_SECS=5
  elif [ "$FAIL_COUNT" -ge 5 ]; then
    SLEEP_SECS=60
  elif [ "$FAIL_COUNT" -ge 3 ]; then
    SLEEP_SECS=30
  elif [ "$FAIL_COUNT" -ge 1 ]; then
    SLEEP_SECS=15
  else
    SLEEP_SECS=5
  fi
  echo "qinglong-launcher: wrapper exit=$EXIT_CODE after ${ELAPSED}s, listened=$LISTENED, retry in ${SLEEP_SECS}s" >> "$LOG_FILE"
  sleep "$SLEEP_SECS"
done
