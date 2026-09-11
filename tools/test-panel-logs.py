#!/usr/bin/env python3
"""The panels' logs: every request, the right level, and nothing secret.

All three run here on real sockets - the admin panel, the relays' API on the
exit, and the customer panel on the relay - and what they print is read back.
Warnings and errors must carry journald's level prefix, so that
`smartdns-logs -e` finds them; a request must leave one line saying what it
was, what came back and who asked; and no password, token, cookie or the
admin panel's secret path may ever appear.
"""
import http.client
import importlib.machinery
import importlib.util
import io
import os
import shutil
import sys
import tempfile
import threading
import time
import urllib.parse

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
REAL = sys.stdout
fails = []


def check(label, cond, detail=""):
    REAL.write(("  ok   " if cond else "  FAIL ") + label +
               ((" - " + str(detail)[-900:]) if detail and not cond else "") + "\n")
    REAL.flush()
    if not cond:
        fails.append(label)


def say(text):
    REAL.write(text + "\n")
    REAL.flush()


def load(name, fname):
    spec = importlib.util.spec_from_loader(
        name, importlib.machinery.SourceFileLoader(
            name, os.path.join(HERE, "..", "templates", fname)))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


admin = load("admin", "smartdns-admin")
panel = load("panel", "smartdns-panel")
sync = load("sync", "smartdns-sync")


class Capture(io.TextIOBase):
    """Everything the servers print, from whichever thread prints it."""

    def __init__(self):
        self.parts, self.lock = [], threading.Lock()

    def write(self, s):
        with self.lock:
            self.parts.append(s)
        return len(s)

    def flush(self):
        pass

    def text(self):
        with self.lock:
            return "".join(self.parts)


cap = Capture()
sys.stdout = cap


def mark():
    return len(cap.text())


def since(at):
    time.sleep(0.15)          # the server thread may still be writing
    return cap.text()[at:]


def request(port, method, path, body=None, headers=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        c.request(method, path, body=body, headers=headers or {})
        r = c.getresponse()
        data = r.read()
        return r.status, dict(r.getheaders()), data
    except (http.client.HTTPException, OSError):
        return None, {}, b""
    finally:
        c.close()


def serve(srv):
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv.server_address[1]


FORM = {"Content-Type": "application/x-www-form-urlencoded"}

# ------------------------------------------------------------------ levels
say("levels journald understands")
for name, m in (("admin", admin), ("api", panel), ("relay", sync)):
    at = mark()
    m.log(m.WARN, "first\nsecond")
    m.log(m.INFO, "ordinary")
    out = since(at)
    check("%s: a warning carries <4> on every line, info carries nothing" % name,
          out == "<4>first\n<4>second\nordinary\n", repr(out))
    try:
        {}["missing"]
    except KeyError:
        at = mark()
        m.log_exception("it broke")
    out = since(at)
    check("%s: an exception comes with its traceback, all of it at error" % name,
          "Traceback" in out and "KeyError" in out
          and all(l.startswith("<3>") for l in out.splitlines()), out)

# ------------------------------------------------------------ admin panel
say("the admin panel")
tmp = tempfile.mkdtemp()
db = os.path.join(tmp, "panel.db")
pstore = panel.Store(db)
default = pstore.ensure_default_template([])["id"]
SECRET = "s3cr3tpath"
SALT = "a1" * 16          # hex, as the installer generates it
admin.CFG = {"ADMIN_PATH": SECRET, "ADMIN_SALT": SALT, "ADMIN_PORT": "0",
             "ADMIN_HASH": admin.hash_password("right-pw", SALT)}
admin.STORE = admin.Store(db)
admin.CATALOGUE = []
aport = serve(admin.make_admin_server(None, 0))

at = mark()
status, _, _ = request(aport, "GET", "/%s/" % SECRET)
out = since(at)
check("a request leaves one line: method, path, answer, time, who",
      "admin GET /<admin>/ 200 " in out and "ms from 127.0.0.1" in out, out)
check("with the secret path masked", SECRET not in out, out)

at = mark()
request(aport, "POST", "/%s/" % SECRET, urllib.parse.urlencode({"password": "wrong-pw"}), FORM)
out = since(at)
check("a failed login is a warning, with where it came from",
      "<4>admin login failed from 127.0.0.1 (1 in a row)" in out, out)
check("and never the password tried", "wrong-pw" not in out, out)

at = mark()
status, hdrs, _ = request(aport, "POST", "/%s/" % SECRET,
                          urllib.parse.urlencode({"password": "right-pw"}), FORM)
out = since(at)
token = hdrs.get("Set-Cookie", "").split("sdns=", 1)[-1].split(";")[0]
check("a login is noted", "admin login from 127.0.0.1" in out and status == 303, out)
check("without the password or the session it opened",
      "right-pw" not in out and token and token not in out, out)
COOKIE = dict(FORM, Cookie="sdns=%s" % token)

at = mark()
request(aport, "POST", "/%s/user-save" % SECRET,
        urllib.parse.urlencode({"id": "7", "quota_gb": "abc"}), COOKIE)
out = since(at)
check("an action is logged with what was asked",
      "admin action user-save id=7 quota_gb=abc" in out, out)
check("and a refusal as a warning, saying why",
      "<4>admin user-save refused: عدد سهمیه درست نیست" in out, out)

at = mark()
request(aport, "POST", "/%s/template-save" % SECRET,
        urllib.parse.urlencode({"id": str(default), "g": ["a.main"],
                                "d": ["d%d.example" % i for i in range(30)]}, doseq=True),
        COOKIE)
out = since(at)
check("a long list is logged as a count, not thirty names", "d=[30]" in out, out)
check("secret-looking fields are masked whatever the action",
      admin.describe({"new_password": ["hunter2"], "id": ["1"]}) == " id=1 new_password=***")

at = mark()
status, _, _ = request(aport, "GET", "/wp-login.php")
out = since(at)
check("a stranger's 404 is an ordinary line with the path",
      status == 404 and "admin GET /wp-login.php 404" in out and "<4>" not in out, out)

saved_view = admin.Admin.view
admin.Admin.view = lambda self, rest: 1 / 0
at = mark()
status, _, _ = request(aport, "GET", "/%s/users" % SECRET, headers=COOKIE)
out = since(at)
admin.Admin.view = saved_view
check("a page that fails answers 500", status == 500, status)
check("and is logged as an error with its traceback",
      "<3>admin GET users failed" in out and "<3>ZeroDivisionError" in out, out)
check("its request line is an error too", "<3>admin GET /<admin>/users 500" in out, out)

saved_get = admin.Admin.do_GET
admin.Admin.do_GET = lambda self: {}["escaped"]
at = mark()
request(aport, "GET", "/%s/" % SECRET)
out = since(at)
admin.Admin.do_GET = saved_get
check("an exception nothing caught is logged with its traceback",
      "<3>request from 127.0.0.1 failed" in out and "<3>KeyError: 'escaped'" in out, out)

# ---------------------------------------------------------------- the API
say("the relays' API on the exit")
panel.CATALOGUE = []
panel.DEFAULT_TEMPLATE[0] = default
panel.API.store, panel.API.secret, panel.API.relays = pstore, "tok", ("127.0.0.1",)
xport = serve(panel.make_api_server(None, 0))


def api(path, obj, tok="tok"):
    import json
    return request(xport, "POST", path, json.dumps(obj),
                   {"Authorization": "Bearer " + tok, "Content-Type": "application/json"})


at = mark()
status, _, _ = api("/sync", {}, tok="wrong")
out = since(at)
# The status is not checked here: the API refuses before reading the body, so
# the client may see its connection reset rather than the 401 - it has said
# what it had to. The line in the log is what this is about.
check("a paired relay with the wrong secret is a warning that says so",
      status in (401, None)
      and "<4>api: 127.0.0.1 is a paired relay but sent the wrong secret" in out,
      out)

at = mark()
status, _, _ = api("/sync", {"counters": {}})
out = since(at)
check("a sync that works is the heartbeat, and says nothing",
      status == 200 and "/sync" not in out, out)

pstore.create_web_user("sara", "Sara", "good-secret")
at = mark()
api("/user-password-login", {"username": "sara", "password": "bad-secret", "ip": "5.6.7.8"})
out = since(at)
check("a customer's failed login names the account and where from",
      "api login failed for 'sara' from 5.6.7.8" in out, out)
check("never the password", "bad-secret" not in out, out)

import json as _json
at = mark()
status, _, body = api("/user-password-login",
                      {"username": "sara", "password": "good-secret", "ip": "5.6.7.8"})
session = _json.loads(body or b"{}").get("session", "")
out = since(at)
check("a login names the customer", "api login: user #" in out and "(sara) from 5.6.7.8" in out,
      out)
check("without the password or the session",
      "good-secret" not in out and session and session not in out, out)

at = mark()
api("/user-info", {"session": session, "ip": "5.6.7.8"})
out = since(at)
check("a customer's request line says which customer",
      "api POST /user-info 200" in out and "from 127.0.0.1 user #" in out, out)

pstore.profiles = lambda *a: 1 / 0
at = mark()
api("/sync", {"counters": {}})
out = since(at)
del pstore.profiles
check("a sync that crashes is logged with its traceback",
      "<3>request from 127.0.0.1 failed" in out and "<3>ZeroDivisionError" in out, out)

# ------------------------------------------------------ customer panel
say("the customer panel on the relay")
sync.CFG = {"PANEL_DOMAIN": "localhost", "PANEL_HOST": "203.0.113.1",
            "SELF_IP": "198.51.100.1", "SYNC_SECRET": "x", "SYNC_FINGERPRINT": "x"}


def fake_post(path, payload):
    if path == "/user-info":
        raise OSError("exit unreachable")
    return {"ok": False, "message": "نام کاربری یا رمز درست نیست"}


sync.post = fake_post
uport = serve(sync.make_panel_server(None, 0))

at = mark()
status, _, _ = request(uport, "GET", "/signup")
out = since(at)
check("a page view leaves its line", status == 200 and "panel GET /signup 200" in out, out)

at = mark()
status, _, _ = request(uport, "GET", "/", headers={"Cookie": "sdu=sess-value-123"})
out = since(at)
check("the exit being unreachable is an error, saying what failed",
      status == 502 and "<3>panel: user-info failed: exit unreachable" in out, out)
check("and the page that failed is an error line", "<3>panel GET / 502" in out, out)
check("the customer's session is never written", "sess-value-123" not in out, out)

at = mark()
request(uport, "POST", "/login", urllib.parse.urlencode(
    {"username": "sara", "password": "p4ssw0rd-x"}), FORM)
out = since(at)
check("a login attempt is a line, without the password",
      "panel POST /login 303" in out and "p4ssw0rd-x" not in out, out)

saved_dash = sync.UserPanel.dashboard
sync.UserPanel.dashboard = lambda self: {}["boom"]
at = mark()
request(uport, "GET", "/", headers={"Cookie": "sdu=abc"})
out = since(at)
sync.UserPanel.dashboard = saved_dash
check("an exception nothing caught is logged with its traceback",
      "<3>request from 127.0.0.1 failed" in out and "<3>KeyError: 'boom'" in out, out)

sys.stdout = REAL
shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
