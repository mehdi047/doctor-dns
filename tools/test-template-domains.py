#!/usr/bin/env python3
"""Per-domain template selection: what the admin ticks is what the relay does.

The thing worth testing is not the checkbox but the consequence. A domain
switched off inside a service the template otherwise routes has to end up in
that template's bypass list, which is the list the relay writes into the
profile's resolver - and everything else about the template has to be
unaffected, including the rule that a service means "everything in it, now
and later".
"""
import importlib.machinery
import importlib.util
import os
import shutil
import sys
import tempfile

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_loader(
    "panel", importlib.machinery.SourceFileLoader(
        "panel", os.path.join(HERE, "..", "templates", "smartdns-panel")))
panel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(panel)

fails = []


def check(label, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + label +
          ((" - " + detail) if detail and not cond else ""))
    if not cond:
        fails.append(label)


CATALOGUE = [
    {"key": "spotify", "label": "Spotify", "groups": [
        {"key": "main", "label": "همه",
         "domains": ["scdn.co", "spotify.com", "spotifycdn.com"]}]},
    {"key": "playstation", "label": "PlayStation", "groups": [
        {"key": "main", "label": "فروشگاه",
         "domains": ["playstation.com", "sony.com"]},
        {"key": "download", "label": "دانلود بازی",
         "domains": ["gs2.ww.prod.dl.playstation.net"]}]},
    {"key": "custom", "label": "دامنه‌های دلخواه", "groups": [
        {"key": "main", "label": "همه", "domains": []}]},
]

tmp = tempfile.mkdtemp()
db_path = os.path.join(tmp, "panel.db")
store = panel.Store(db_path)
default = store.ensure_default_template(CATALOGUE)["id"]

cur = store.run("INSERT INTO templates (name, is_default, created_at)"
                " VALUES ('موزیک', 0, ?)", (panel.now(),))
tid = cur.lastrowid
for skey, gkey in (("spotify", "main"), ("playstation", "main")):
    store.run("INSERT INTO template_services (template_id, service_key, group_key)"
              " VALUES (?, ?, ?)", (tid, skey, gkey))

print("a template with whole services ticked and nothing switched off")
bypass = store.bypass_for(tid, CATALOGUE)
check("routes every Spotify domain",
      not any(d in bypass for d in ("scdn.co", "spotify.com", "spotifycdn.com")),
      str(bypass))
check("bypasses the PlayStation download group it did not tick",
      "gs2.ww.prod.dl.playstation.net" in bypass, str(bypass))

print("switching off one domain inside a service that is ticked")
store.run("INSERT INTO template_domains_off (template_id, domain) VALUES (?, ?)",
          (tid, "spotifycdn.com"))
bypass = store.bypass_for(tid, CATALOGUE)
check("that domain is now bypassed", "spotifycdn.com" in bypass, str(bypass))
check("its siblings still route",
      "scdn.co" not in bypass and "spotify.com" not in bypass, str(bypass))
check("an untouched service is unaffected",
      "playstation.com" not in bypass, str(bypass))

print("a service ticked today still covers a domain added tomorrow")
grown = [dict(s, groups=[dict(g, domains=list(g["domains"])) for g in s["groups"]])
         for s in CATALOGUE]
grown[0]["groups"][0]["domains"].append("spotify-everywhere.com")
bypass = store.bypass_for(tid, grown)
check("the new domain routes without anyone re-saving the template",
      "spotify-everywhere.com" not in bypass, str(bypass))
check("the switched-off one stays off", "spotifycdn.com" in bypass, str(bypass))

print("switching off every domain equals not ticking the service")
for d in ("scdn.co", "spotify.com"):
    store.run("INSERT INTO template_domains_off (template_id, domain) VALUES (?, ?)",
              (tid, d))
bypass = store.bypass_for(tid, CATALOGUE)
check("all three Spotify domains bypassed",
      all(d in bypass for d in ("scdn.co", "spotify.com", "spotifycdn.com")),
      str(bypass))

print("the default template is still everything")
check("default bypasses nothing", store.bypass_for(default, CATALOGUE) == [])

print("deleting the template takes its exceptions with it")
store.run("DELETE FROM templates WHERE id = ?", (tid,))
left = store.q("SELECT * FROM template_domains_off WHERE template_id = ?", (tid,))
check("no orphan rows left behind", not left, "%d rows" % len(left))

print("the admin panel's save turns ticks into exactly those rows")
admin_spec = importlib.util.spec_from_loader(
    "admin", importlib.machinery.SourceFileLoader(
        "admin", os.path.join(HERE, "..", "templates", "smartdns-admin")))
admin = importlib.util.module_from_spec(admin_spec)
admin_spec.loader.exec_module(admin)
# The admin panel keeps its own Store class, thinner than the panel's. Handing
# it the panel's would hide any method it is missing - which is exactly the
# bug this line was written after.
admin.STORE = admin.Store(db_path)
admin.CATALOGUE = CATALOGUE
admin.CFG = {"ADMIN_PATH": "p"}

cur = store.run("INSERT INTO templates (name, is_default, created_at)"
                " VALUES ('دوم', 0, ?)", (panel.now(),))
tid2 = cur.lastrowid


class Recorder:
    def __init__(self):
        self._headers_buffer = []
        self.sent = {}

    def send_response(self, code):
        self.sent["code"] = code

    def send_header(self, k, v):
        ("%s: %s\r\n" % (k, v)).encode("latin-1")   # what http.server does
        self.sent[k] = v

    def end_headers(self):
        pass

    class _W:
        def write(self, b):
            pass
    wfile = _W()


rec = Recorder()
for name in ("action", "redirect", "send"):
    setattr(Recorder, name, getattr(admin.Admin, name))
# one() is a staticmethod on Admin; copying it across plainly would make it
# an instance method here and hand it self as the first argument.
Recorder.one = staticmethod(admin.Admin.one)
# Spotify ticked with one domain left out; PlayStation download ticked whole.
rec.action("template-save", {
    "id": [str(tid2)],
    "g": ["spotify.main", "playstation.download"],
    "d": ["scdn.co", "spotify.com", "gs2.ww.prod.dl.playstation.net"],
})
check("save redirected back to this template",
      "templates?t=%d" % tid2 in rec.sent.get("Location", ""),
      rec.sent.get("Location", ""))
groups = store.template_groups(tid2)
check("both ticked groups stored",
      groups == {("spotify", "main"), ("playstation", "download")}, str(groups))
off = store.template_domains_off(tid2)
check("only the unticked domain is stored as an exception",
      off == {"spotifycdn.com"}, str(off))
bypass = store.bypass_for(tid2, CATALOGUE)
check("the storefront group nobody ticked is bypassed",
      "playstation.com" in bypass and "sony.com" in bypass, str(bypass))
check("the download group ticked is routed",
      "gs2.ww.prod.dl.playstation.net" not in bypass, str(bypass))

print("the editor page renders against the admin panel's own Store")
class Page:
    path = "/p/templates?t=%d" % tid2
for name in ("templates", "template_editor", "template_list"):
    setattr(Page, name, getattr(admin.Admin, name))
html_out = Page().templates()
check("the editor renders", "<details" in html_out, html_out[:200])
check("it lists the domains", "spotifycdn.com" in html_out)
check("the drawer with an exception is open", "<details class='svc' open>" in html_out)
list_out = Page.template_list(Page())
check("the list renders", "قالب تازه" in list_out, list_out[:200])
check("the list links to the editor", "templates?t=%d" % tid2 in list_out)

print("saving again with the drawer never opened keeps every domain")
rec2 = Recorder()
rec2.action("template-save", {
    "id": [str(tid2)], "g": ["spotify.main"],
    "d": ["scdn.co", "spotify.com", "spotifycdn.com"],
})
check("no exceptions recorded", store.template_domains_off(tid2) == set(),
      str(store.template_domains_off(tid2)))

shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
