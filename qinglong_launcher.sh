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
set -x
export HOME=/home/kasm-user
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
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
echo "qinglong-launcher: QL_DIR=$QL_DIR QL_DATA_DIR=$QL_DATA_DIR" >&2
command -v node >/dev/null 2>&1 || { echo "qinglong-launcher: node not found" >&2; exit 1; }
command -v qinglong >/dev/null 2>&1 || { echo "qinglong-launcher: qinglong command not found" >&2; exit 1; }
node --version >&2
# Keep it running: restart 5s after an exit, log to the data dir.
while true; do
  echo "qinglong-launcher: starting qinglong on :5700" >&2
  qinglong >>"$QL_DATA_DIR/../qinglong.log" 2>&1
  echo "qinglong-launcher: qinglong exited, restarting in 5s" >&2
  sleep 5
done
