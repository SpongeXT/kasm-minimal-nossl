#!/bin/bash
# Launch one ROOT terminal in the minimal Chrome image, once the desktop is up.
# Runs from vnc_startup.sh right after start_kasmvnc, in the background.
# Single admin account only: the terminal runs as root, so Leon can install
# things and run scripts without permission errors. No su, no user switching
# in this script — root comes from passwordless sudo, which the Dockerfile
# sets up (sudo installed, "kasm-user ALL=(ALL) NOPASSWD: ALL").
# If sudo is not available for any reason, fall back to a normal terminal.
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
  xfconf-query -c xfce4-keyboard-shortcuts -p "/commands/custom/<Primary><Alt>t" -n -t string -s "sudo xfce4-terminal" || true
fi
if command -v sudo >/dev/null 2>&1 && command -v xfce4-terminal >/dev/null 2>&1; then
  sudo -n xfce4-terminal &
elif command -v xfce4-terminal >/dev/null 2>&1; then
  xfce4-terminal &
elif command -v xterm >/dev/null 2>&1; then
  xterm &
fi
wait
echo "terminal-launcher: done" >&2
