#!/bin/bash
# Launch one terminal in the minimal Chrome image, once the desktop is up.
# Runs from vnc_startup.sh right after start_kasmvnc, in the background.
# Simple version: no su, no user switching at all — just run the terminal
# directly as whoever is already running this script.
set -x
if command -v /usr/bin/desktop_ready >/dev/null 2>&1; then
  /usr/bin/desktop_ready || true
else
  sleep 15
fi
export DISPLAY=:1 HOME=/home/kasm-user XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus"
if command -v xfconf-query >/dev/null 2>&1; then
  xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s false || true
  xfconf-query -c xfwm4 -p /general/vblank_mode -n -t string -s "xpresent" || true
  xfconf-query -c xfce4-keyboard-shortcuts -p "/commands/custom/<Primary><Alt>t" -n -t string -s "xfce4-terminal" || true
fi
if command -v xfce4-terminal >/dev/null 2>&1; then
  xfce4-terminal &
elif command -v xterm >/dev/null 2>&1; then
  xterm &
fi
wait
echo "terminal-launcher: done" >&2
