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
# --- Terminal + login gate ---
# python3 for the proxy, xfce4-terminal for Leon, xterm as a tiny fallback,
# openbox as the window manager (click-to-focus, title bar, Alt+Tab).
# Do NOT overwrite /dockerstartup/custom_startup.sh — kasmweb/chrome ships
# its own there (Chrome watchdog; replacing it breaks the desktop).
# Instead hook both the proxy and the terminal launcher into
# vnc_startup.sh right after the `start_kasmvnc` call (sed insert, build
# fails if the hook line is absent).
RUN apt-get update -qq && apt-get install -y --no-install-recommends python3 python3-tk xfce4-terminal xterm sudo wmctrl xbindkeys openbox \
 && echo 'kasm-user ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/kasm-user && chmod 440 /etc/sudoers.d/kasm-user \
 && rm -rf /var/lib/apt/lists/* \
 && python3 --version \
 && python3 -c "import tkinter; print('tk ok')" \
 && which xfce4-terminal xterm openbox
COPY desk_auth_proxy.py /usr/local/bin/desk_auth_proxy.py
COPY terminal_launcher.sh /usr/local/bin/terminal_launcher.sh
COPY term_button.py /usr/local/bin/term_button.py
RUN chmod +x /usr/local/bin/desk_auth_proxy.py /usr/local/bin/terminal_launcher.sh /usr/local/bin/term_button.py \
 && sed -i 's#^start_kasmvnc$#start_kasmvnc\n(while true; do python3 /usr/local/bin/desk_auth_proxy.py; echo "desk-auth-proxy exited, restarting in 2s" >\&2; sleep 2; done) \&\n( /usr/local/bin/terminal_launcher.sh || true ) \&#' /dockerstartup/vnc_startup.sh \
 && grep -q 'desk_auth_proxy.py' /dockerstartup/vnc_startup.sh || { echo "proxy hook missing" >&2; exit 1; } \
 && grep -q 'terminal_launcher.sh' /dockerstartup/vnc_startup.sh || { echo "terminal hook missing" >&2; exit 1; } \
 && echo "proxy hook OK" \
 && echo "terminal hook OK" \
 && grep -n 'desk_auth_proxy\|terminal_launcher' /dockerstartup/vnc_startup.sh || true
USER 1000
