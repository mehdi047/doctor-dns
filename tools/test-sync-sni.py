#!/usr/bin/env python3
"""The relay's sync puts a name in its TLS handshake with the exit.

It dials the exit by address, and Python sends no name (SNI) in TLS for an
address. Filtering between Iran and some exits resets exactly those
handshakes - measured on a live relay: no name, reset every time; any name,
through every time - and sync and the customer panel went down with it.

These run the real post() against a real TLS server with a self-signed
certificate that records the name it was handed, and hold the pinning to
what it was: a certificate that does not match is refused, and the secret is
never sent to it.
"""
import hashlib
import http.server
import importlib.machinery
import importlib.util
import json
import os
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
fails = []


def check(label, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + label +
          ((" - " + str(detail)[:400]) if detail and not cond else ""))
    if not cond:
        fails.append(label)


if shutil.which("openssl") is None:
    print("openssl not available - skipping")
    sys.exit(0)

tmp = tempfile.mkdtemp()
cert, key = os.path.join(tmp, "c.pem"), os.path.join(tmp, "k.pem")
subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=exit"],
               capture_output=True, env=dict(os.environ, MSYS_NO_PATHCONV="1"))
if not os.path.exists(cert):
    print("could not make a test certificate - skipping")
    sys.exit(0)

spec = importlib.util.spec_from_loader(
    "sync", importlib.machinery.SourceFileLoader(
        "sync", os.path.join(HERE, "..", "templates", "smartdns-sync")))
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)

seen = {"sni": [], "auth": [], "paths": []}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(length)
        seen["auth"].append(self.headers.get("Authorization", ""))
        seen["paths"].append(self.path)
        body = json.dumps({"allowed": []}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
ctx.sni_callback = lambda sock, name, c: seen["sni"].append(name)
httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
port = httpd.server_address[1]
threading.Thread(target=httpd.serve_forever, daemon=True).start()

der = ssl.PEM_cert_to_DER_cert(open(cert).read())
fingerprint = hashlib.sha256(der).hexdigest()

# post() dials port 8443; point it at the test server's port instead.
real = sync.NamedHTTPS


class ToTestPort(real):
    def __init__(self, host, port, sni, **kw):
        super().__init__(host, globals()["port"], sni, **kw)


sync.NamedHTTPS = ToTestPort


def call(cfg):
    seen["sni"].clear()
    seen["auth"].clear()
    seen["paths"].clear()
    sync.CFG = dict({"PANEL_HOST": "127.0.0.1", "SYNC_SECRET": "s3cret",
                     "SYNC_FINGERPRINT": fingerprint, "SELF_IP": "198.51.100.1"}, **cfg)
    try:
        return sync.post("/sync", {"counters": {}}), None
    except Exception as e:
        return None, e


print("dialled by address, it still names itself")
answer, err = call({"PANEL_DOMAIN": "panel.example.org"})
check("the sync goes through", err is None and answer == {"allowed": []}, repr(err))
check("with the relay's own domain as the name", seen["sni"] == ["panel.example.org"],
      seen["sni"])
check("and the secret, once the certificate matched", seen["auth"] == ["Bearer s3cret"],
      seen["auth"])

answer, err = call({})
check("a relay with no domain uses the placeholder", seen["sni"] == ["sync.example.com"],
      seen["sni"])

answer, err = call({"PANEL_DOMAIN": "panel.example.org", "SYNC_SNI": "other.example.net"})
check("SYNC_SNI in sync.env wins over both", seen["sni"] == ["other.example.net"], seen["sni"])

print("the pinning is what it was")
answer, err = call({"SYNC_FINGERPRINT": "0" * 64})
check("a certificate that does not match is refused", err is not None
      and "fingerprint mismatch" in str(err), repr(err))
check("and the secret never went to it", seen["auth"] == [] and seen["paths"] == [],
      seen)

print("the installer checks the same path")
logic = open(os.path.join(HERE, "installer-logic.sh"), encoding="utf-8").read()
at = logic.find('check "the exit\'s sync API answers this relay"')
check("there is a check for it", at > 0)
line = logic[at:logic.index("\n", logic.index("\n", at) + 1)]
check("it names itself the same way", '${PANEL_DOMAIN:-sync.example.com}:8443:${EXIT_IP}' in line,
      line)
check("and asks with a GET, so no secret is involved", '"501"' in line and "-X POST" not in line,
      line)

httpd.shutdown()
shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
