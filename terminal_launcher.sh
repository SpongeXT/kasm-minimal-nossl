#!/bin/bash
# Launch one ordinary terminal in the minimal Chrome image, ON TOP of Chrome,
# and make Ctrl+Alt+T open a terminal at any time.
# Runs from vnc_startup.sh right after start_kasmvnc, in the background.
# Single user, no su, no sudo, no user switching: Altare blocks privilege
# escalation with "no new privileges", so everything runs directly as the
# current user.
# Why the delay: Chrome starts after the desktop is ready and always ends up
# maximized on top, covering a terminal opened earlier. So this script waits
# ~20 seconds for Chrome to finish starting, then opens the terminal with a
# fixed size and position, and uses wmctrl to raise it above Chrome.
# Why the shortcut failed before (2026-11-24 02:04 test): xbindkeys was
# started immediately after desktop_ready, before the X server was really
# ready to accept clients, so it most likely died silently on startup and
# was never retried — Ctrl+Alt+T then did nothing, both while a terminal
# was open and after it was closed, and the closed terminal never came
# back. Fix: start xbindkeys LATE (after the 20s Chrome wait), with an
# explicit config path and display, verbose logging, and a retry loop that
# verifies with pgrep that it is actually still running. Also start
# xfconfd first if present, so the xfconf shortcut binding can register
# as a backup. And as a safety net, the terminal now auto-relaunches:
# if it is closed, a new one opens ~2s later, so the desktop is never
# left with no terminal even if the shortcut still fails.
set -x
if command -v /usr/bin/desktop_ready >/dev/null 2>&1; then
  /usr/bin/desktop_ready || true
else
  sleep 15
fi
export DISPLAY=:1 HOME=/home/kasm-user XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus"
[ -f "$HOME/.Xauthority" ] && export XAUTHORITY="$HOME/.Xauthority"
# Ctrl+Alt+T -> open a terminal. Config written early, daemon started late.
cat > /home/kasm-user/.xbindkeysrc <<'EOF'
"xfce4-terminal --geometry=100x28+40+40"
  control+alt+t
EOF
# Let Chrome come up first so it cannot cover the terminal afterwards.
sleep 20
# Settings service, if present: without xfconfd running, xfconf-query
# cannot connect and the xfconf shortcut binding never registers.
if command -v xfconfd >/dev/null 2>&1; then
  pgrep -x xfconfd >/dev/null 2>&1 || xfconfd &
  sleep 1
fi
# xbindkeys, LATE, with verification: X is definitely up now.
# -f explicit config, -X explicit display, -v logs to /tmp/xbindkeys.log.
if command -v xbindkeys >/dev/null 2>&1; then
  for i in 1 2 3 4 5; do
    pgrep -x xbindkeys >/dev/null 2>&1 && break
    xbindkeys -f /home/kasm-user/.xbindkeysrc -X :1 -v >/tmp/xbindkeys.log 2>&1 &
    sleep 2
    if pgrep -x xbindkeys >/dev/null 2>&1; then
      echo "terminal-launcher: xbindkeys running, pid $(pgrep -x xbindkeys | head -1)" >&2
      break
    fi
    echo "terminal-launcher: xbindkeys not running after attempt $i, retrying" >&2
  done
  pgrep -x xbindkeys >/dev/null 2>&1 || echo "terminal-launcher: WARNING xbindkeys FAILED to stay running" >&2
fi
# Compositor off + Ctrl+Alt+T binding via xfconf, best effort only
# (xfconf may be absent in this image; xbindkeys above is the real shortcut).
if command -v xfconf-query >/dev/null 2>&1; then
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s false 2>/dev/null; then
      xfconf-query -c xfwm4 -p /general/vblank_mode -n -t string -s "xpresent" || true
      xfconf-query -c xfce4-keyboard-shortcuts -p "/commands/custom/<Primary><Alt>t" -n -t string -s "xfce4-terminal" || true
      break
    fi
    sleep 3
  done
fi
# Terminal, with auto-relaunch: closing it opens a fresh one ~2s later.
# This loop is the script's main foreground job; xbindkeys keeps running
# in the background alongside it.
if command -v xfce4-terminal >/dev/null 2>&1; then
  TERM_CMD="xfce4-terminal --geometry=100x28+40+40"
elif command -v xterm >/dev/null 2>&1; then
  TERM_CMD="xterm -geometry 100x28+40+40"
else
  echo "terminal-launcher: no terminal found" >&2
  exit 1
fi
while true; do
  $TERM_CMD &
  TERM_PID=$!
  sleep 3
  if command -v wmctrl >/dev/null 2>&1; then
    for i in 1 2 3 4 5 6; do
      sleep 2
      wmctrl -a Terminal 2>/dev/null && break
      wmctrl -x -a xfce4-terminal.Xfce4-terminal 2>/dev/null && break
    done
  fi
  wait $TERM_PID
  echo "terminal-launcher: terminal exited, reopening in 2s" >&2
  sleep 2
done
