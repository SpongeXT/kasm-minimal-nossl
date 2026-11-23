#!/usr/bin/env python3
"""Login-gate reverse proxy for KasmVNC.

Listens on 0.0.0.0:6902 and forwards to KasmVNC on 127.0.0.1:6901,
but only after the visitor passes a form login. The password comes
from the DESK_PW environment variable (set in the Altare console);
nothing secret is baked into the image.

Why a form login instead of Kasm's own password: KasmVNC uses HTTP
BasicAuth, and Altare's Go proxy never sends credentials, so every
visit 401s and trips Kasm's brute-force blacklist. A form login +
session cookie travels fine through the proxy, and the websocket
stream Kasm needs is spliced through byte-for-byte after login.

Lockout: 5 failed logins from one key locks that key out for 10
minutes. The key is the visitor IP from X-Forwarded-For when the
Altare proxy passes it, else the peer IP (in that case every visitor
shares one key and a lock affects everyone until it expires or the
app restarts).
"""

import hashlib
import hmac
import http.client
import os
import secrets
import select
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

UPSTREAM_HOST = "127.0.0.1"
UPSTREAM_PORT = 6901
LISTEN_PORT = 6902
COOKIE_NAME = "desk_session"
SESSION_TTL = 7 * 24 * 3600  # 7 days

PASSWORD = os.environ.get("DESK_PW", "")
if PASSWORD:
    print("desk-auth-proxy: DESK_PW is set, logins enabled", flush=True)
else:
    print("desk-auth-proxy: WARNING: DESK_PW is not set, all logins will fail",
          flush=True)

SESSIONS = {}
SESSIONS_LOCK = threading.Lock()

MAX_FAILS = 5
LOCK_SECONDS = 600  # 10 minutes
FAILS = {}  # key -> {"count": int, "locked_until": float}
FAILS_LOCK = threading.Lock()


def client_key(handler):
    """Key for rate limiting: real visitor IP if the Altare proxy passes
    X-Forwarded-For, else the peer IP (all visitors then share one key)."""
    xff = handler.headers.get("X-Forwarded-For", "")
    if xff:
        return xff.split(",")[0].strip()
    return handler.client_address[0]


def is_locked(key):
    with FAILS_LOCK:
        entry = FAILS.get(key)
        return bool(entry and entry["locked_until"] > time.time())


def record_fail(key):
    """Count a failed login; returns True if the key is now locked."""
    now = time.time()
    with FAILS_LOCK:
        entry = FAILS.setdefault(key, {"count": 0, "locked_until": 0})
        if entry["locked_until"] > now:
            return True
        entry["count"] += 1
        if entry["count"] >= MAX_FAILS:
            entry["locked_until"] = now + LOCK_SECONDS
            entry["count"] = 0
            print("desk-auth-proxy: LOCKED %s for %d seconds after %d failures"
                  % (key, LOCK_SECONDS, MAX_FAILS), flush=True)
            return True
        return False


def reset_fails(key):
    with FAILS_LOCK:
        FAILS.pop(key, None)


def new_session():
    token = secrets.token_urlsafe(32)
    with SESSIONS_LOCK:
        SESSIONS[token] = time.time() + SESSION_TTL
    return token


def valid_session(token):
    if not token:
        return False
    now = time.time()
    with SESSIONS_LOCK:
        exp = SESSIONS.get(token)
        if exp and exp > now:
            return True
        SESSIONS.pop(token, None)
    return False


def drop_session(token):
    if token:
        with SESSIONS_LOCK:
            SESSIONS.pop(token, None)


LOGIN_PAGE = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>桌面登录</title>
<style>
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
background:#1a1d23;font-family:-apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;color:#e8e8e8}
.card{background:#24272e;border:1px solid #3a3d45;border-radius:12px;padding:32px 28px;width:300px;
box-shadow:0 8px 32px rgba(0,0,0,.45)}
h1{font-size:20px;margin:0 0 6px;text-align:center}
p{font-size:13px;color:#9aa0aa;margin:0 0 20px;text-align:center}
.err{color:#ff7b72;font-size:13px;text-align:center;margin:0 0 12px;min-height:18px}
input{width:100%;box-sizing:border-box;padding:11px 12px;border-radius:8px;border:1px solid #4a4e57;
background:#1a1d23;color:#e8e8e8;font-size:15px;outline:none}
input:focus{border-color:#4f8cff}
button{width:100%;margin-top:14px;padding:11px;border:0;border-radius:8px;background:#4f8cff;color:#fff;
font-size:15px;cursor:pointer}
button:hover{background:#3d7bef}
</style></head><body><div class="card">
<h1>桌面登录</h1><p>请输入密码进入远程桌面</p>
<p class="err">{err}</p>
<form method="post" action="/login">
<input type="password" name="password" placeholder="密码" autofocus required>
<button type="submit">进入桌面</button>
</form></div></body></html>
"""

HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-connection", "te", "trailer",
    "proxy-authorization", "transfer-encoding", "upgrade",
}


def client_ip(handler):
    return handler.client_address[0]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("desk-auth-proxy: %s - %s\n"
                         % (client_ip(self), fmt % args))
        sys.stderr.flush()

    # -- session helpers -------------------------------------------------
    def session_token(self):
        cookie = self.headers.get("Cookie", "")
        for part in cookie.split(";"):
            part = part.strip()
            if part.startswith(COOKIE_NAME + "="):
                return part[len(COOKIE_NAME) + 1:]
        return ""

    def send_login_page(self, err=""):
        # NB: plain replace, not str.format -- the page CSS is full of braces.
        body = LOGIN_PAGE.replace("{err}", err).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, location, set_cookie=None, clear_cookie=False):
        self.send_response(302)
        if set_cookie is not None:
            self.send_header(
                "Set-Cookie",
                "%s=%s; Path=/; HttpOnly; SameSite=Lax" % (COOKIE_NAME, set_cookie))
        if clear_cookie:
            self.send_header(
                "Set-Cookie",
                "%s=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0" % COOKIE_NAME)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    # -- routing ---------------------------------------------------------
    def do_GET(self):
        self._handle()

    def do_POST(self):
        self._handle()

    def do_PUT(self):
        self._handle()

    def do_DELETE(self):
        self._handle()

    def do_HEAD(self):
        self._handle()

    def do_OPTIONS(self):
        self._handle()

    def do_PATCH(self):
        self._handle()

    def _handle(self):
        path = urlparse(self.path).path
        if self.command == "POST" and path == "/login":
            self._do_login()
            return
        if path == "/logout":
            drop_session(self.session_token())
            self.redirect("/", clear_cookie=True)
            return
        if not valid_session(self.session_token()):
            if self.command == "GET" and path == "/":
                query = urlparse(self.path).query or ""
                if "err=locked" in query:
                    err = "尝试次数过多，请 10 分钟后再试。"
                elif "err=1" in query:
                    err = "密码错误，请重试。"
                else:
                    err = ""
                self.send_login_page(err)
            else:
                # API / asset / websocket without a session: send them to login.
                self.redirect("/")
            return
        # Authenticated: proxy to KasmVNC.
        if self.headers.get("Upgrade", "").lower() == "websocket":
            self._proxy_websocket()
        else:
            self._proxy_http()

    def _do_login(self):
        key = client_key(self)
        if is_locked(key):
            print("desk-auth-proxy: login BLOCKED (locked) for %s" % key, flush=True)
            self.redirect("/?err=locked")
            return
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length > 0 else b""
        fields = parse_qs(raw.decode("utf-8", "ignore"))
        attempt = (fields.get("password") or [""])[0]
        ok = bool(PASSWORD) and hmac.compare_digest(attempt, PASSWORD)
        if ok:
            reset_fails(key)
            print("desk-auth-proxy: login OK from %s" % client_ip(self), flush=True)
            self.redirect("/", set_cookie=new_session())
        else:
            locked = record_fail(key)
            print("desk-auth-proxy: login FAILED from %s" % client_ip(self), flush=True)
            time.sleep(1)  # slow brute force a little
            self.redirect("/?err=locked" if locked else "/?err=1")

    # -- plain HTTP proxy ------------------------------------------------
    def _proxy_http(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length > 0 else None
        conn = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=30)
        try:
            headers = {k: v for k, v in self.headers.items()
                       if k.lower() not in HOP_BY_HOP}
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
        except (OSError, http.client.HTTPException) as exc:
            self._upstream_error(exc)
            return
        finally:
            conn.close()
        self.send_response(resp.status, resp.reason)
        for key, value in resp.getheaders():
            if key.lower() in ("content-length", "transfer-encoding",
                               "connection", "keep-alive"):
                continue
            self.send_header(key, value)
        if self.command != "HEAD":
            self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD" and data:
            self.wfile.write(data)

    def _upstream_error(self, exc):
        print("desk-auth-proxy: upstream error: %s" % exc, flush=True)
        body = ("<html><body><h1>桌面还在启动</h1>"
                "<p>请稍等几秒后刷新重试。</p></body></html>").encode("utf-8")
        try:
            self.send_response(502)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except OSError:
            pass

    # -- websocket proxy (raw TCP splice after the 101 handshake) --------
    def _proxy_websocket(self):
        try:
            upstream = socket.create_connection(
                (UPSTREAM_HOST, UPSTREAM_PORT), timeout=30)
        except OSError as exc:
            self._upstream_error(exc)
            return
        try:
            # Forward the handshake exactly as received (minus proxy headers).
            lines = [self.requestline]
            for key, value in self.headers.items():
                if key.lower() in ("proxy-authorization", "proxy-connection"):
                    continue
                lines.append("%s: %s" % (key, value))
            upstream.sendall(("\r\n".join(lines) + "\r\n\r\n").encode("latin-1"))
            # Read upstream's 101 response headers, forward them verbatim.
            buf = b""
            upstream.settimeout(30)
            while b"\r\n\r\n" not in buf:
                chunk = upstream.recv(4096)
                if not chunk:
                    raise OSError("upstream closed during handshake")
                buf += chunk
            head, rest = buf.split(b"\r\n\r\n", 1)
            self.connection.sendall(head + b"\r\n\r\n")
            if rest:
                self.connection.sendall(rest)
            # Splice bytes both ways until either side closes.
            self._splice(self.connection, upstream)
        except OSError as exc:
            print("desk-auth-proxy: websocket error: %s" % exc, flush=True)
        finally:
            try:
                upstream.close()
            except OSError:
                pass

    @staticmethod
    def _splice(a, b):
        for sock in (a, b):
            sock.setblocking(False)
        sockets = [a, b]
        try:
            while True:
                readable, _, _ = select.select(sockets, [], [], 1.0)
                if not readable:
                    continue
                for src in readable:
                    dst = b if src is a else a
                    try:
                        data = src.recv(65536)
                    except OSError:
                        return
                    if not data:
                        return
                    try:
                        dst.sendall(data)
                    except OSError:
                        return
        except (OSError, ValueError):
            return


def main():
    server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    server.daemon_threads = True
    print("desk-auth-proxy: listening on 0.0.0.0:%d -> %s:%d"
          % (LISTEN_PORT, UPSTREAM_HOST, UPSTREAM_PORT), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
