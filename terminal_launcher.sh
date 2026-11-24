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
# as a backup. (Auto-relaunch was removed 2026-11-24 at Leon's request: with a
# window manager the terminal can be minimized, and it reopens from the on-screen
# button or Ctrl+Alt+T, so closing it no longer needs to bring it straight back.)
# Why the keyboard did not reach the terminal (2026-11-24 09:04, Leon's report):
# this image has no window manager, so clicking the terminal never moves keyboard
# focus off Chrome — mouse works in the terminal, every keystroke goes to Chrome.
# Fix: start openbox (tiny window manager) before opening the terminal. It gives
# every window a title bar with minimize/maximize/close, click-to-focus and Alt+Tab.
# With minimize working, Leon can minimize the terminal to browse; closing it still
# auto-reopens (safety net).
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
# Window manager: without one, clicking the terminal never moves keyboard
# focus off Chrome (mouse works, keys go to Chrome). openbox gives every
# window a title bar, click-to-focus and Alt+Tab.
if command -v openbox >/dev/null 2>&1; then
  pgrep -x openbox >/dev/null 2>&1 || openbox &
  sleep 2
  echo "terminal-launcher: openbox started" >&2
fi
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
# On-screen "终端" button (top-right corner, always on top): tap it and a
# terminal opens. No keyboard needed — tap it and a terminal opens.
# Started here, after Chrome is up, so it lands on top of Chrome.
if [ -x /usr/local/bin/term_button.py ]; then
  pgrep -f term_button.py >/dev/null 2>&1 || (python3 /usr/local/bin/term_button.py >/tmp/term_button.log 2>&1 &)
  echo "terminal-launcher: term button started" >&2
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
# Terminal, opened once: no auto-relaunch (removed 2026-11-24 at Leon's request).
# Closing it leaves Chrome clear; reopen with the "终端" button or Ctrl+Alt+T.
# The launcher stays alive on `wait` so the background helpers (openbox,
# xbindkeys, term button) keep running.
if command -v xfce4-terminal >/dev/null 2>&1; then
  TERM_CMD="xfce4-terminal --geometry=100x28+40+40"
elif command -v xterm >/dev/null 2>&1; then
  TERM_CMD="xterm -geometry 100x28+40+40"
else
  echo "terminal-launcher: no terminal found" >&2
  exit 1
fi
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
echo "terminal-launcher: terminal closed, not reopening" >&2
wait
