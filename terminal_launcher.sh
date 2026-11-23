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
# Why xbindkeys for the shortcut: the XFCE settings service (xfconfd) that
# would normally register Ctrl+Alt+T does not run in this single-app image,
# so xfconf-query bindings never took. xbindkeys grabs the key combo directly
# from the X server instead, no settings service needed.
set -x
if command -v /usr/bin/desktop_ready >/dev/null 2>&1; then
  /usr/bin/desktop_ready || true
else
  sleep 15
fi
export DISPLAY=:1 HOME=/home/kasm-user XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus"
# Ctrl+Alt+T -> open a terminal, via xbindkeys (X-level key grab).
if command -v xbindkeys >/dev/null 2>&1; then
  cat > /home/kasm-user/.xbindkeysrc <<'EOF'
"xfce4-terminal"
  control+alt+t
EOF
  pgrep -x xbindkeys >/dev/null 2>&1 || xbindkeys &
fi
# Let Chrome come up first so it cannot cover the terminal afterwards.
sleep 20
if command -v xfce4-terminal >/dev/null 2>&1; then
  xfce4-terminal --geometry=100x28+40+40 &
elif command -v xterm >/dev/null 2>&1; then
  xterm -geometry 100x28+40+40 &
fi
# Raise the terminal above Chrome, retrying while Chrome is still starting.
if command -v wmctrl >/dev/null 2>&1; then
  for i in 1 2 3 4 5 6; do
    sleep 2
    wmctrl -a Terminal 2>/dev/null && break
    wmctrl -x -a xfce4-terminal.Xfce4-terminal 2>/dev/null && break
  done
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
wait
echo "terminal-launcher: done" >&2
