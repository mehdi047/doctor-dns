#!/usr/bin/env python3
"""One stalled visitor must not freeze the customer panel for everybody.

The panel used to wrap its listening socket in TLS. That runs each visitor's
handshake inside accept(), on the single thread that accepts for all of them,
with no deadline - so a phone whose connection dropped half way through a
handshake froze the panel for everyone until it went away. On mobile in Iran
that is routine, and it was reported by the first operator to install this:
a customer sent their receipt, and the page stopped loading.

These drive the real server class, with a real TLS handshake, against
visitors that misbehave the ways real networks do.
"""
import http.client
import importlib.machinery
import importlib.util
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
fails = []


def check(label, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + label +
          ((" - " + detail) if detail and not cond else ""))
    if not cond:
        fails.append(label)


if shutil.which("openssl") is None:
    print("openssl not available - skipping")
    sys.exit(0)

tmp = tempfile.mkdtemp()
cert, key = os.path.join(tmp, "c.pem"), os.path.join(tmp, "k.pem")
# MSYS_NO_PATHCONV: on git-bash for Windows a leading slash in -subj is taken
# for a path and rewritten, and openssl then fails without saying why.
subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", key, "-out", cert, "-days", "1",
                "-subj", "/CN=localhost"],
               capture_output=True, env=dict(os.environ, MSYS_NO_PATHCONV="1"))
if not os.path.exists(cert):
    print("could not make a test certificate - skipping")
    sys.exit(0)

spec = importlib.util.spec_from_loader(
    "sync", importlib.machinery.SourceFileLoader(
        "sync", os.path.join(HERE, "..", "templates", "smartdns-sync")))
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)
sync.CFG = {"PANEL_DOMAIN": "localhost", "PANEL_HOST": "203.0.113.1"}
# Short deadlines, so a test that waits for one does not wait ten seconds.
sync.HANDSHAKE_TIMEOUT = 2
sync.IO_TIMEOUT = 3

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
httpd = sync.make_panel_server(ctx, port=0)
port = httpd.server_address[1]
threading.Thread(target=httpd.serve_forever, daemon=True).start()

client = ssl.create_default_context()
client.check_hostname = False
client.verify_mode = ssl.CERT_NONE


def visit(timeout=4):
    """(answered?, seconds) for a real visitor loading the sign-up page."""
    t = time.time()
    try:
        r = urllib.request.urlopen("https://127.0.0.1:%d/signup" % port,
                                   context=client, timeout=timeout)
        r.read()
        return r.status == 200, time.time() - t
    except Exception:
        return False, time.time() - t


print("a normal visitor gets the page")
ok, took = visit()
check("it answers", ok)
check("quickly", took < 1.5, "%.2fs" % took)

print("one visitor stalls in the handshake - the next is not kept waiting")
# Connects and says nothing: a phone whose signal went, mid-handshake.
stalled = socket.create_connection(("127.0.0.1", port))
time.sleep(0.3)
ok, took = visit()
check("the next visitor still gets the page", ok)
check("without waiting on the stalled one", took < 1.5, "%.2fs" % took)

print("twenty stall at once")
crowd = [socket.create_connection(("127.0.0.1", port)) for _ in range(20)]
time.sleep(0.3)
ok, took = visit()
check("a real visitor still gets through", ok)
check("promptly", took < 1.5, "%.2fs" % took)

print("somebody speaks plain http to the https port")
junk = socket.create_connection(("127.0.0.1", port))
junk.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
time.sleep(0.3)
ok, took = visit()
check("it does not take the server down", ok)

print("and a stalled handshake is let go, not held forever")
# The deadline is 2s here. After it, the server has closed its side, which
# the stalled client sees as the connection ending.
stalled.settimeout(5)
t = time.time()
try:
    closed = stalled.recv(1) == b""
except (ConnectionResetError, OSError):
    closed = True
except socket.timeout:
    closed = False
waited = time.time() - t
check("the server hangs up on it", closed, "still open after %.1fs" % waited)
check("within the handshake deadline", waited < sync.HANDSHAKE_TIMEOUT + 2,
      "%.1fs" % waited)

print("and still, after all of that")
ok, took = visit()
check("the panel answers", ok)

for s in [stalled, junk] + crowd:
    try:
        s.close()
    except OSError:
        pass

print("the listening socket is not wrapped any more")
src = open(os.path.join(HERE, "..", "templates", "smartdns-sync"),
           encoding="utf-8").read()
serve = src[src.index("def serve_panel"):]
serve = serve[:serve.index("httpd.serve_forever()")]
check("serve_panel does not wrap httpd.socket",
      "httpd.socket = " not in serve, serve[:300])
check("the handshake happens per connection",
      "def finish_request" in src and "wrap_socket(request" in src)

httpd.shutdown()

print("the admin panel and the relays' API, built the same way now")
# Both wrapped their listening socket, as the customer panel did. On the API
# that was the worst place for it: one silent connection to the exit's port
# and no relay could sync - nobody new let in, nobody out of time cut off.
for label, fname in (("admin panel", "smartdns-admin"), ("relay API", "smartdns-panel")):
    spec = importlib.util.spec_from_loader(
        label, importlib.machinery.SourceFileLoader(
            label, os.path.join(HERE, "..", "templates", fname)))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    m.HANDSHAKE_TIMEOUT, m.IO_TIMEOUT = 2, 3
    if fname == "smartdns-admin":
        m.CFG = {"ADMIN_PATH": "secret"}
        srv = m.make_admin_server(ctx, 0)
    else:
        srv = m.make_api_server(ctx, 0)
    p = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    held = [socket.create_connection(("127.0.0.1", p)) for _ in range(5)]
    time.sleep(0.3)
    t = time.time()
    try:
        c = http.client.HTTPSConnection("127.0.0.1", p, context=client, timeout=4)
        c.request("GET", "/")
        status = c.getresponse().status
        c.close()
    except Exception as e:
        status = "no answer (%s)" % e
    took = time.time() - t
    check("%s: answers past five stalled handshakes" % label,
          isinstance(status, int), str(status))
    check("%s: promptly" % label, took < 1.5, "%.2fs" % took)
    for s in held:
        s.close()
    srv.shutdown()
    msrc = open(os.path.join(HERE, "..", "templates", fname), encoding="utf-8").read()
    check("%s: its listening socket is not wrapped" % label,
          "httpd.socket = ctx.wrap_socket" not in msrc)

shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
