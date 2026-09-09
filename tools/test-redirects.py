#!/usr/bin/env python3
"""Check that every redirect these panels send can survive a header.

An HTTP header carries latin-1 and nothing else. Every message the admin panel
shows after an action is Persian and travels in the Location header's query
string, so an unencoded one makes send_header raise in the middle of a
response - and the browser reports corrupted content, after the action has
already been carried out. That failed silently for every button on the panel,
so it gets a test.
"""
import importlib.machinery
import importlib.util
import io
import os
import re
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATES = os.path.join(HERE, "..", "templates")

fails = []


def check(label, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + label +
          ((" - " + detail) if detail and not cond else ""))
    if not cond:
        fails.append(label)


def load(name):
    path = os.path.join(TEMPLATES, name)
    spec = importlib.util.spec_from_loader(
        name.replace("-", "_"),
        importlib.machinery.SourceFileLoader(name.replace("-", "_"), path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Recorder:
    """Stands in for the handler's socket plumbing and records the headers."""

    def __init__(self):
        self.headers_out = []
        self._headers_buffer = []
        self.client_address = ("198.51.100.4", 1234)

    def send_response(self, code):
        self.code = code
        # http.server encodes every header line as latin-1, so do the same here
        # rather than trusting a comment that says it does.
        self._headers_buffer.append(("HTTP/1.1 %d\r\n" % code).encode("latin-1"))

    def send_header(self, key, value):
        self._headers_buffer.append(
            ("%s: %s\r\n" % (key, value)).encode("latin-1"))
        self.headers_out.append((key, value))

    def end_headers(self):
        pass

    class _W:
        def write(self, b):
            pass
    wfile = _W()


print("admin panel: every redirect in action()")
admin = load("smartdns-admin")
admin.CFG = {"ADMIN_PATH": "5e7812858ba68c7448f7013a"}

source = io.open(os.path.join(TEMPLATES, "smartdns-admin"), encoding="utf-8").read()
targets = re.findall(r'self\.redirect\(\s*"((?:[^"\\]|\\.)*)"', source, re.S)
targets += re.findall(r'self\.redirect\(\s*"((?:[^"\\]|\\.)*)"\s*%', source, re.S)
# The ones built with % formatting carry a domain or an error string; stand a
# Persian value in for the placeholder so the test sees the worst case.
targets = [t.replace("%s", "دامنهٔ آزمایشی") for t in set(targets)]
targets += ["users?m=ذخیره شد", "settings?m=!خطا در ذخیره", ""]
check("found the redirects to test", len(targets) > 10, "%d found" % len(targets))

for target in sorted(set(targets)):
    rec = Recorder()
    rec.redirect = admin.Admin.redirect.__get__(rec, Recorder)
    rec.send = admin.Admin.send.__get__(rec, Recorder)
    try:
        rec.redirect(target)
        loc = dict(rec.headers_out).get("Location", "")
        ok = bool(loc) and loc.isascii()
    except Exception as e:
        ok, loc = False, repr(e)
    check("redirect(%r)" % (target[:44] + ("…" if len(target) > 44 else "")),
          ok, loc)

print("admin panel: a half-written response is not prepended to the next one")
rec = Recorder()
rec.send = admin.Admin.send.__get__(rec, Recorder)
rec._headers_buffer = [b"HTTP/1.1 303 See Other\r\n", b"Server: leftover\r\n"]
rec.send("<h1>error</h1>", 500)
starts = [b for b in rec._headers_buffer if b.startswith(b"HTTP/1.1")]
check("only one status line goes out", len(starts) == 1,
      "%d status lines" % len(starts))

print("user panel: messages in a Location are encoded too")
sync = load("smartdns-sync")
for message in ["آی‌پی 198.51.100.4 ثبت شد", "شماره یا رمز درست نیست", ""]:
    rec = Recorder()
    rec.path = "/"
    rec.redirect = sync.UserPanel.redirect.__get__(rec, Recorder)
    rec.send = sync.UserPanel.send.__get__(rec, Recorder)
    try:
        rec.redirect("/", message, bad=True)
        loc = dict(rec.headers_out).get("Location", "")
        ok = bool(loc) and loc.isascii()
    except Exception as e:
        ok, loc = False, repr(e)
    check("user redirect(%r)" % message[:28], ok, loc)

print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
