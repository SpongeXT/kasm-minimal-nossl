FROM kasmweb/chrome:1.17.0
USER root
# Minimal Chrome + terminal image.
# Base is kasmweb/chrome (single-application Chrome, no xfce4-panel, no file
# manager, no full desktop) — it browsed reliably before, unlike the full
# kasmweb/desktop image whose xfwm4 kept segfaulting after framebuffer
# resize and left a black screen with "Unable to contact settings server".
# Added on top, nothing else: xfce4-terminal (+ xterm fallback) so Leon can
# run scripts (e.g. Baidu Netdisk sign-in) in the desktop, and the same
# DESK_PW login-gate proxy on 6902 as the other images.
# Plus QingLong panel (npm version, NOT Docker-in-Docker): Docker in Docker
# was tried 2026-11-24 and failed — the container's seccomp policy blocks
# creating user namespaces, so no dockerd can start. QingLong itself is a
# Node.js app, so it is installed with npm and runs directly as kasm-user.
# It listens on 5700, reachable only from Chrome inside this container at
# http://localhost:5700 (Altare only exposes 6902 externally).
# --- KasmVNC: plain HTTP, no BasicAuth (Altare's Go proxy sends no creds) ---
# Replace -sslOnly with -disableBasicAuth on the vncserver line(s).
# Fail the build if -sslOnly remains or -disableBasicAuth is missing.
RUN sed -i.bak 's/-sslOnly/-disableBasicAuth/g' /dockerstartup/vnc_startup.sh \
 && if grep -q '\-sslOnly' /dockerstartup/vnc_startup.sh; then echo "sslOnly still present" >&2; exit 1; fi \
 && if ! grep -q '\-disableBasicAuth' /dockerstartup/vnc_startup.sh; then echo "disableBasicAuth missing" >&2; exit 1; fi \
 && echo "sslOnly -> disableBasicAuth OK" \
 && grep -n "vncserver " /dockerstartup/vnc_startup.sh || true
# Belt and braces: KasmVNC also reads /etc/kasmvnc/kasmvnc.yaml.
RUN mkdir -p /etc/kasmvnc \
 && printf 'network:\n  ssl:\n    require_ssl: false\n' > /etc/kasmvnc/kasmvnc.yaml \
 && cat /etc/kasmvnc/kasmvnc.yaml
# --- Node.js + QingLong (npm, no Docker) ---
# QingLong 2.24.0 npm package is verified on Node.js 20 and 24; panel and
# script dependencies use pnpm 8.3.1. Installed as root at build time, runs
# as kasm-user at runtime (no root needed: its scheduler is internal).
RUN apt-get update -qq && apt-get install -y --no-install-recommends curl ca-certificates gnupg git python3-pip \
 && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && node --version && npm --version \
 && npm install -g pnpm@8.3.1 @whyour/qinglong@2.24.0 \
 && which node npm pnpm qinglong \
 && ls "$(npm root -g)/@whyour/qinglong" >/dev/null && echo "qinglong installed" \
 && pip3 install requests pycryptodome \
 && python3 -c "import requests, Crypto; print('py deps ok')" \
 && rm -rf /var/lib/apt/lists/* /root/.npm /root/.cache
# --- Terminal + login gate ---
# python3 for the proxy, xfce4-terminal for Leon, xterm as a tiny fallback,
# openbox as the window manager (click-to-focus, title bar, Alt+Tab).
# Do NOT overwrite /dockerstartup/custom_startup.sh — kasmweb/chrome ships
# its own there (Chrome watchdog; replacing it breaks the desktop).
# Instead hook the proxy, the terminal launcher and the QingLong launcher
# into vnc_startup.sh right after the `start_kasmvnc` call (sed insert,
# build fails if a hook line is absent).
RUN apt-get update -qq && apt-get install -y --no-install-recommends python3 python3-tk xfce4-terminal xterm sudo wmctrl xbindkeys openbox \
 && echo 'kasm-user ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/kasm-user && chmod 440 /etc/sudoers.d/kasm-user \
 && rm -rf /var/lib/apt/lists/* \
 && python3 --version \
 && python3 -c "import tkinter; print('tk ok')" \
 && which xfce4-terminal xterm openbox
COPY desk_auth_proxy.py /usr/local/bin/desk_auth_proxy.py
COPY terminal_launcher.sh /usr/local/bin/terminal_launcher.sh
COPY term_button.py /usr/local/bin/term_button.py
COPY qinglong_launcher.sh /usr/local/bin/qinglong_launcher.sh
RUN chmod +x /usr/local/bin/desk_auth_proxy.py /usr/local/bin/terminal_launcher.sh /usr/local/bin/term_button.py /usr/local/bin/qinglong_launcher.sh \
 && sed -i 's#^start_kasmvnc$#start_kasmvnc\n(while true; do python3 /usr/local/bin/desk_auth_proxy.py; echo "desk-auth-proxy exited, restarting in 2s" >\&2; sleep 2; done) \&\n( /usr/local/bin/terminal_launcher.sh || true ) \&\n( /usr/local/bin/qinglong_launcher.sh || true ) \&#' /dockerstartup/vnc_startup.sh \
 && grep -q 'desk_auth_proxy.py' /dockerstartup/vnc_startup.sh || { echo "proxy hook missing" >&2; exit 1; } \
 && grep -q 'terminal_launcher.sh' /dockerstartup/vnc_startup.sh || { echo "terminal hook missing" >&2; exit 1; } \
 && grep -q 'qinglong_launcher.sh' /dockerstartup/vnc_startup.sh || { echo "qinglong hook missing" >&2; exit 1; } \
 && echo "proxy hook OK" \
 && echo "terminal hook OK" \
 && echo "qinglong hook OK" \
 && grep -n 'desk_auth_proxy\|terminal_launcher\|qinglong_launcher' /dockerstartup/vnc_startup.sh || true
USER 1000
