#!/bin/bash
# Launch one terminal in the minimal Chrome image, once the desktop is up.
# Runs from vnc_startup.sh (as root) right after start_kasmvnc, in the
# background, so it must not block vnc_startup.sh.
# The terminal itself runs as kasm-user (1000) with DISPLAY=:1.
# Also (best effort, ignored on failure):
#  - turn xfwm4 compositing OFF and vblank_mode=xpresent via xfconf-query,
#    so the GLX/compositor path that segfaulted xfwm4 on resize in the full
#    desktop image is not used here either;
#  - bind Ctrl+Alt+T to xfce4-terminal, so Leon can reopen a terminal any
#    time after closing the first one (Alt+Tab switches back to Chrome).
set -x
# Wait until the desktop is ready (desktop_ready blocks until it is).
# It may not exist on some images; fall back to a plain sleep then.
if command -v /usr/bin/desktop_ready >/dev/null 2>&1; then
  /usr/bin/desktop_ready || true
else
  sleep 15
fi
su kasm-user -s /bin/bash -c '
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
' || true
echo "terminal-launcher: done" >&2
