#!/bin/bash
# Launch one ordinary terminal in the minimal Chrome image, once the desktop is up.
# Runs from vnc_startup.sh right after start_kasmvnc, in the background.
# No su, no sudo, no user switching: Altare blocks privilege escalation with
# "no new privileges", so the terminal runs directly as the current user.
# The terminal is launched FIRST so it opens even if the shortcut binding
# below cannot reach xfconf yet; the binding is then retried in the background.
set -x
if command -v /usr/bin/desktop_ready >/dev/null 2>&1; then
  /usr/bin/desktop_ready || true
else
  sleep 15
fi
export DISPLAY=:1 HOME=/home/kasm-user XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus"
if command -v xfce4-terminal >/dev/null 2>&1; then
  xfce4-terminal &
elif command -v xterm >/dev/null 2>&1; then
  xterm &
fi
# Bind Ctrl+Alt+T and turn the compositor off, retrying while xfconf is
# still starting up (earlier builds failed here with "Failed to init libxfconf").
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
