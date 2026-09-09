#!/usr/bin/env python3
"""Payment receipts, end to end, and the admin's day field.

A receipt is the one thing a customer sends that the operator acts on with
money involved, so what matters is that only their own account can be charged
with it, that rubbish is refused, and that the image does not outlive the
decision it was evidence for.
"""
import base64
import importlib.machinery
import importlib.util
import os
import shutil
import sys
import tempfile
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
sync = load("smartdns-sync", "sync")

tmp = tempfile.mkdtemp()
db_path = os.path.join(tmp, "panel.db")
store = panel.Store(db_path)
admin.DB = db_path
admin.CFG = {"ADMIN_PATH": "p"}
admin.STORE = admin.Store(db_path)

store.run("INSERT INTO users (phone, first_name, created_at)"
          " VALUES ('09120000001', 'پرداخت‌کننده', ?)", (panel.now(),))
store.run("INSERT INTO users (phone, first_name, created_at, expires_at)"
          " VALUES ('09120000002', 'دیگری', ?, ?)", (panel.now(), panel.now()))
session = store.open_session(1)
other = store.open_session(2)

# A one-pixel PNG is a real image with a real header, so this exercises the
# type check rather than sneaking past it.
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM"
    "IQAAAABJRU5ErkJggg==")


class Api:
    def __init__(self, store):
        self.store = store


for name in ("do_user_receipt", "_session_user"):
    setattr(Api, name, getattr(panel.API, name))
api = Api(store)

print("a customer sends a receipt")
res = api.do_user_receipt({"session": session, "content_type": "image/png",
                           "data": base64.b64encode(PNG).decode()})
check("it is accepted", res.get("ok"), str(res))
row = store.one("SELECT * FROM transactions WHERE user_id = 1")
check("stored against the right account", row is not None)
check("the bytes came through intact", bytes(row["receipt_blob"]) == PNG)
check("the type is recorded", row["receipt_type"] == "image/png")
check("it starts pending", row["status"] == "pending")

print("what is refused")
for body, why in [
        ({"session": session, "content_type": "text/html",
          "data": base64.b64encode(b"<script>").decode()}, "an html file"),
        ({"session": session, "content_type": "image/png",
          "data": "not base64 !!"}, "a corrupt upload"),
        ({"session": session, "content_type": "image/png", "data": ""},
         "an empty file"),
        ({"session": "nonsense", "content_type": "image/png",
          "data": base64.b64encode(PNG).decode()}, "no valid session"),
        ({"session": session, "content_type": "image/png",
          "data": base64.b64encode(b"x" * (panel.MAX_RECEIPT + 1)).decode()},
         "an oversized file")]:
    check("refuses %s" % why, not api.do_user_receipt(body).get("ok"))

print("a second receipt replaces the first, it does not queue")
api.do_user_receipt({"session": session, "content_type": "image/jpeg",
                     "data": base64.b64encode(b"\xff\xd8\xff" + PNG).decode()})
rows = store.q("SELECT * FROM transactions WHERE user_id = 1 AND status = 'pending'")
check("still exactly one pending", len(rows) == 1, "%d rows" % len(rows))
check("it is the newer one", rows[0]["receipt_type"] == "image/jpeg")

print("one customer cannot touch another's")
api.do_user_receipt({"session": other, "content_type": "image/png",
                     "data": base64.b64encode(PNG).decode()})
check("each account has its own",
      store.one("SELECT count(*) c FROM transactions WHERE user_id = 1")["c"] == 1
      and store.one("SELECT count(*) c FROM transactions WHERE user_id = 2")["c"] == 1)


class Rec:
    def __init__(self):
        self._headers_buffer = []
        self.sent = {}
        self.written = b""

    def send_response(self, code):
        self.sent["code"] = code

    def send_header(self, k, v):
        ("%s: %s\r\n" % (k, v)).encode("latin-1")
        self.sent[k] = v

    def end_headers(self):
        pass

    class _W:
        def __init__(self, outer):
            self.outer = outer

        def write(self, b):
            self.outer.written += b
    wfile = None


for name in ("action", "redirect", "send", "receipts", "send_receipt"):
    setattr(Rec, name, getattr(admin.Admin, name))
Rec.one = staticmethod(admin.Admin.one)

print("the admin panel shows it and serves the image")
rec = Rec(); rec.wfile = Rec._W(rec)
page = rec.receipts()
check("the pending one is listed", "رسیدهای در انتظار (2)" in page, page[:120])
check("it names the customer", "پرداخت‌کننده" in page)
check("it links to the image", "/p/receipt/" in page)

tid = store.one("SELECT id FROM transactions WHERE user_id = 2")["id"]
rec2 = Rec(); rec2.wfile = Rec._W(rec2)
rec2.send_receipt(str(tid))
check("the image is served with its own type",
      rec2.sent.get("Content-Type") == "image/png", str(rec2.sent))
check("the bytes are the ones stored", rec2.written == PNG)

rec3 = Rec(); rec3.wfile = Rec._W(rec3)
rec3.send_receipt("9999")
check("an unknown id is a 404", rec3.sent.get("code") == 404)

print("deciding clears the image but keeps the record")
rec4 = Rec(); rec4.wfile = Rec._W(rec4)
rec4.action("receipt-decide", {"id": [str(tid)], "to": ["approved"]})
after = store.one("SELECT * FROM transactions WHERE id = ?", (tid,))
check("the decision is recorded", after["status"] == "approved")
check("it is timestamped", bool(after["decided_at"]))
check("the image is gone", after["receipt_blob"] is None)
rec5 = Rec(); rec5.wfile = Rec._W(rec5)
rec5.send_receipt(str(tid))
check("and can no longer be fetched", rec5.sent.get("code") == 404)

rec6 = Rec(); rec6.wfile = Rec._W(rec6)
rec6.action("receipt-decide", {"id": [str(tid)], "to": ["something"]})
# The message is percent-encoded into the Location, so decode before looking
# for the leading '!' that marks an error message.
where = urllib.parse.unquote(rec6.sent.get("Location", ""))
check("an invalid decision is refused", "m=!" in where, where)

print("zero days means no time limit")
before = store.one("SELECT expires_at FROM users WHERE id = 2")
check("the account had an end date", bool(before["expires_at"]))
store.run("UPDATE users SET status = 'expired' WHERE id = 2")
rec7 = Rec(); rec7.wfile = Rec._W(rec7)
rec7.action("user-save", {"id": ["2"], "quota_gb": ["5"], "days": ["0"]})
u = store.one("SELECT * FROM users WHERE id = 2")
check("the end date is cleared", u["expires_at"] is None, str(u["expires_at"]))
check("so is the renewal date", u["quota_reset_at"] is None)
check("an expired account comes back", u["status"] == "active", u["status"])
check("the quota it was given still applies", u["quota_bytes"] == 5 * (1024 ** 3))
check("no end date reads as unlimited",
      admin.remaining_days(None) == "بی‌نهایت", admin.remaining_days(None))

rec8 = Rec(); rec8.wfile = Rec._W(rec8)
rec8.action("user-save", {"id": ["2"], "quota_gb": ["5"], "days": ["7"]})
u = store.one("SELECT expires_at, quota_reset_at FROM users WHERE id = 2")
check("a positive number still sets a date",
      bool(u["quota_reset_at"]), str(dict(u)))

print("an expired cookie does not block the way back in")
src_sync = open(os.path.join(HERE, "..", "templates", "smartdns-sync"),
                encoding="utf-8").read()
sign = src_sync[src_sync.index('if path in ("/signup", "/login"):'):]
sign = sign[:sign.index("if path == ")]
check("the signup page does not redirect on a cookie",
      "return self.redirect" not in sign, sign[:200])
check("it still offers a way back to the account",
      "برگشت به حساب" in sign)

print("the settings page no longer offers a name or an address lock")
src = open(os.path.join(HERE, "..", "templates", "smartdns-admin"),
           encoding="utf-8").read()
check("no service name field", "service_name" not in src)
check("no address lock", "admin_ips" not in src and "address_allowed" not in src)
check("the relay names itself after its domain",
      "PANEL_DOMAIN" in open(
          os.path.join(HERE, "..", "templates", "smartdns-sync"),
          encoding="utf-8").read())

shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
