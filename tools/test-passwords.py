#!/usr/bin/env python3
"""Changing passwords, and moving the admin panel.

Three things that all fail the same way if they are wrong - somebody loses
access to something they own. So what is checked is mostly the refusals: a
wrong current password, a typo in the confirmation, a port that would take
the service down, a path short enough to guess.
"""
import importlib.machinery
import importlib.util
import os
import shutil
import sys
import tempfile
import threading
import urllib.parse

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


def load(name, mod):
    spec = importlib.util.spec_from_loader(
        mod, importlib.machinery.SourceFileLoader(
            mod, os.path.join(HERE, "..", "templates", name)))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


panel = load("smartdns-panel", "panel")
admin = load("smartdns-admin", "admin")

tmp = tempfile.mkdtemp()
db_path = os.path.join(tmp, "panel.db")
store = panel.Store(db_path)

store.create_web_user("09120000001", "صاحب حساب", "original-pass")
owner = store.user_by_phone("09120000001")
store.create_web_user("09120000002", "دیگری", "other-pass")
session = store.open_session(owner["id"])
elsewhere = store.open_session(owner["id"])       # the same account, another device


class Api:
    def __init__(self, store):
        self.store = store


for name in ("do_user_password", "_session_user"):
    setattr(Api, name, getattr(panel.API, name))
api = Api(store)

print("a customer changes their own password")
panel.THROTTLE.clear("pw:%d" % owner["id"])
res = api.do_user_password({"session": session, "current": "original-pass",
                            "new": "a-better-password"})
check("accepted", res.get("ok"), str(res))
check("the new password works",
      panel.check_password(store.user_by_phone("09120000001"), "a-better-password"))
check("the old one does not",
      not panel.check_password(store.user_by_phone("09120000001"), "original-pass"))
check("their other session was ended",
      api._session_user(elsewhere) is None)
check("the session they used still works",
      api._session_user(session) is not None)

print("what it refuses")
panel.THROTTLE.clear("pw:%d" % owner["id"])
for body, why in [
        ({"session": session, "current": "wrong", "new": "long-enough-x"},
         "a wrong current password"),
        ({"session": session, "current": "a-better-password", "new": "short"},
         "a new password that is too short"),
        ({"session": session, "current": "a-better-password",
          "new": "a-better-password"}, "reusing the same password"),
        ({"session": "not-a-session", "current": "a-better-password",
          "new": "long-enough-x"}, "no valid session")]:
    panel.THROTTLE.clear("pw:%d" % owner["id"])
    r = api.do_user_password(body)
    check("refuses %s" % why, not r.get("ok"), str(r))
check("and the password is unchanged",
      panel.check_password(store.user_by_phone("09120000001"), "a-better-password"))

print("guessing the current password is throttled")
panel.THROTTLE.clear("pw:%d" % owner["id"])
for _ in range(8):
    api.do_user_password({"session": session, "current": "no",
                          "new": "long-enough-x"})
blocked = api.do_user_password({"session": session, "current": "no",
                                "new": "long-enough-x"})
check("the ninth attempt is made to wait", "دقیقه" in blocked.get("message", ""),
      str(blocked))

print("one customer cannot change another's")
panel.THROTTLE.clear("pw:%d" % owner["id"])
other = store.open_session(store.user_by_phone("09120000002")["id"])
api.do_user_password({"session": other, "current": "other-pass",
                      "new": "changed-by-them"})
check("only their own account moved",
      panel.check_password(store.user_by_phone("09120000001"), "a-better-password")
      and panel.check_password(store.user_by_phone("09120000002"),
                               "changed-by-them"))

# ---------------------------------------------------------------- admin
conf = os.path.join(tmp, "admin.env")
open(conf, "w", newline="\n").write(
    "ADMIN_PORT=9443\nADMIN_PATH=originalpath01\n"
    "ADMIN_SALT=00112233445566778899aabbccddeeff\nADMIN_HASH=deadbeef\n"
    "ADMIN_CERT=/etc/letsencrypt/live/panel.example.com/fullchain.pem\n")
admin.CONFIG = conf
admin.DB = db_path
admin.STORE = admin.Store(db_path)
admin.CFG = {"ADMIN_PATH": "originalpath01", "ADMIN_PORT": "9443",
             "ADMIN_SALT": "00112233445566778899aabbccddeeff",
             "ADMIN_HASH": "deadbeef",
             "ADMIN_CERT": "/etc/letsencrypt/live/panel.example.com/fullchain.pem"}
admin.STORE.run(
    "INSERT OR REPLACE INTO admin_sessions (token, expires_at) VALUES (?, ?)",
    ("tok", (panel.datetime.now(panel.timezone.utc)
             + panel.timedelta(hours=12)).isoformat(timespec="seconds")))
moved = []


class FakeThreading:
    """Only Timer is replaced - Store still needs a real Lock."""
    Lock = threading.Lock

    @staticmethod
    def Timer(*a, **kw):
        return type("t", (), {"start": lambda self: moved.append(True)})()


admin.threading = FakeThreading


class Rec:
    def __init__(self):
        self._headers_buffer = []
        self.sent = {}
        self.headers = {"Cookie": "sdns=tok"}

    def send_response(self, code):
        self.sent["code"] = code

    def send_header(self, k, v):
        ("%s: %s\r\n" % (k, v)).encode("latin-1")
        self.sent[k] = v

    def end_headers(self):
        pass

    class _W:
        def write(self, b):
            pass

        def flush(self):
            pass
    wfile = _W()


for n in ("action", "redirect", "send", "moving_to", "settings",
          "session_token", "session_ok"):
    setattr(Rec, n, getattr(admin.Admin, n))
Rec.one = staticmethod(admin.Admin.one)


def where(r):
    return urllib.parse.unquote(r.sent.get("Location", ""))


def conf_value(key):
    for line in open(conf, encoding="utf-8"):
        if line.startswith(key + "="):
            return line.split("=", 1)[1].strip()
    return None


print("the admin's password is asked for twice")
r = Rec()
r.action("password", {"password": ["a-good-password"], "again": ["a-typo"]})
check("a mismatch is refused", "m=!" in where(r), where(r))
check("nothing was written", conf_value("ADMIN_HASH") == "deadbeef")

r = Rec()
r.action("password", {"password": ["short"], "again": ["short"]})
check("a short one is refused", "m=!" in where(r), where(r))

r = Rec()
r.action("password", {"password": ["a-good-password"], "again": ["a-good-password"]})
check("matching and long enough is accepted", "m=!" not in where(r), where(r))
check("the hash changed", conf_value("ADMIN_HASH") != "deadbeef")
check("the password is not in the file",
      "a-good-password" not in open(conf, encoding="utf-8").read())

print("moving the panel's port")
for bad, why in [("443", "https"), ("53", "dns"), ("8443", "the sync API"),
                 ("22", "ssh"), ("0", "out of range"), ("99999", "out of range"),
                 ("abc", "not a number")]:
    r = Rec()
    r.action("panel-port", {"port": [bad]})
    check("refuses %s (%s)" % (bad, why),
          "m=!" in where(r) and conf_value("ADMIN_PORT") == "9443", where(r)[:80])

moved.clear()
r = Rec()
r.action("panel-port", {"port": ["9500"]})
check("a free port is accepted", conf_value("ADMIN_PORT") == "9500")
check("the new address is shown, not redirected to",
      r.sent.get("code") == 200 and "9500" in r.sent.get("Refresh", ""),
      str(r.sent.get("Refresh")))
check("and it restarts onto it", moved == [True], str(moved))

print("moving the panel's path")
for bad, why in [("short", "too short"), ("has/slash", "a slash"),
                 ("has space", "a space"), ("", "empty")]:
    r = Rec()
    r.action("panel-path", {"path": [bad]})
    check("refuses %r (%s)" % (bad, why),
          "m=!" in where(r) and conf_value("ADMIN_PATH") == "originalpath01",
          where(r)[:80])

r = Rec()
r.action("panel-path", {"path": ["a-new-secret-path"]})
check("an explicit path is accepted", conf_value("ADMIN_PATH") == "a-new-secret-path")

r = Rec()
r.action("panel-path", {"random": ["1"], "path": [""]})
check("a random one is generated", len(conf_value("ADMIN_PATH")) == 24,
      conf_value("ADMIN_PATH"))

print("a stray address does not look like a broken panel")
admin.STORE.run("DELETE FROM admin_sessions")


class Stray(Rec):
    def __init__(self, path, cookie=""):
        Rec.__init__(self)
        self.path = path
        self.headers = {"Cookie": cookie}
        self.client_address = ("198.51.100.9", 3333)


# view() binds every page method into a dict before it checks membership, so
# the stand-in needs all of them or it fails for the wrong reason.
for n in ("lost", "route", "do_GET", "session_ok", "view", "home", "users",
          "receipts", "templates", "domains", "logs", "restore_page",
          "send_backup", "send_receipt"):
    setattr(Stray, n, getattr(admin.Admin, n))

# Nobody signed in: a stranger typing the host learns nothing.
r = Stray("/")
r.do_GET()
check("a stranger gets a bare 404", r.sent.get("code") == 404, str(r.sent))
r = Stray("/wp-admin/")
r.do_GET()
check("and so does a scanner", r.sent.get("code") == 404, str(r.sent))

# Signed in: the same address takes them to the panel instead.
admin.STORE.run(
    "INSERT OR REPLACE INTO admin_sessions (token, expires_at) VALUES (?, ?)",
    ("live", (panel.datetime.now(panel.timezone.utc)
              + panel.timedelta(hours=12)).isoformat(timespec="seconds")))
r = Stray("/", cookie="sdns=live")
r.do_GET()
check("somebody signed in is sent to the panel",
      r.sent.get("code") == 303 and admin.CFG["ADMIN_PATH"] in r.sent.get("Location", ""),
      str(r.sent))
r = Stray("/%s/a-page-that-moved" % admin.CFG["ADMIN_PATH"], cookie="sdns=live")
r.do_GET()
check("so is a bookmark to a page that moved",
      r.sent.get("code") == 303, str(r.sent))

print("a session survives the panel restarting")
# The whole point: the operator is not signed out by an upgrade, so the
# redirect above still works for them afterwards.
admin.STORE.close()
admin.STORE = admin.Store(db_path)          # as if the process had restarted
r = Stray("/", cookie="sdns=live")
r.do_GET()
check("still signed in after a restart", r.sent.get("code") == 303, str(r.sent))
check("an expired one is not", True)
admin.STORE.run(
    "INSERT OR REPLACE INTO admin_sessions (token, expires_at) VALUES (?, ?)",
    ("stale", (panel.datetime.now(panel.timezone.utc)
               - panel.timedelta(minutes=1)).isoformat(timespec="seconds")))
r = Stray("/", cookie="sdns=stale")
r.do_GET()
check("an expired session gets the 404, not the panel",
      r.sent.get("code") == 404, str(r.sent))
check("and is deleted on the way",
      admin.STORE.one("SELECT 1 x FROM admin_sessions WHERE token='stale'") is None)

print("the pages tell the browser there is no favicon to fetch")
src = open(os.path.join(HERE, "..", "templates", "smartdns-admin"),
           encoding="utf-8").read()
check("both the panel and the login page say so",
      src.count('rel="icon" href="data:,"') == 2,
      str(src.count('rel="icon" href="data:,"')))
check("the login form posts to a fixed address",
      'action="/%s/"' in src)

print("the settings page shows the address and warns about the firewall")
page = Rec().settings()
check("it shows where the panel is", "panel.example.com" in page)
check("it asks for the password twice", page.count("type='password'") == 2,
      str(page.count("type='password'")))
check("it warns about the security group", "security group" in page)

shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
