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

print("and what the relay is told is what it can actually obey")
# The bug this was missing. The panel worked out the right list and the relay
# wrote it down, and dnsmasq threw it away: every profile also read the shared
# hijack list, which names each routed domain exactly, and a server= rule
# subtracting one of them ties on longest match and loses to address=. So an
# un-ticked service kept routing, for every ordinary domain, silently.
#
# The rule the relay has to keep is simple: a domain this template must not
# route may not have an address= line anywhere the profile's resolver reads.
sync_spec = importlib.util.spec_from_loader(
    "sync", importlib.machinery.SourceFileLoader(
        "sync", os.path.join(HERE, "..", "templates", "smartdns-sync")))
sync = importlib.util.module_from_spec(sync_spec)
sync_spec.loader.exec_module(sync)

src = open(os.path.join(HERE, "..", "templates", "smartdns-sync"),
           encoding="utf-8").read()
mirror = src[src.index("def sync_base_dir"):]
mirror = mirror[:mirror.index("return changed")]
check("the profiles do not read the shared hijack list",
      "HIJACK_CONF" in mirror, mirror[:300])
check("which is still where the main resolver's rules live",
      'HIJACK_CONF = "/etc/dnsmasq.d/smart-dns.conf"' in src)

# A template only becomes a profile once somebody is actually on it.
store.run("INSERT INTO users (phone, first_name, created_at, status,"
          " quota_bytes, quota_mode, template_id)"
          " VALUES ('09120000077', 't', ?, 'active', 0, 'oneoff', ?)",
          (panel.now(), tid))
store.run("INSERT INTO ips (user_id, ip, added_at) VALUES"
          " ((SELECT id FROM users WHERE phone='09120000077'), '198.51.100.7', ?)",
          (panel.now(),))
_, profs = store.profiles(CATALOGUE, default)
spec = profs[str(tid)]
check("the panel sends what the template routes, positively",
      "routed" in spec, str(sorted(spec)))
routed, bypassed = set(spec["routed"]), set(spec["bypass"])
# Derived from the state this test has built up by now rather than assumed:
# what the template routes is every domain of a ticked group, less the ones
# switched off inside it one at a time.
ticked = store.template_groups(tid)
off = store.template_domains_off(tid)
want = {d for svc in CATALOGUE if svc["key"] != "custom"
        for g in svc["groups"] if (svc["key"], g["key"]) in ticked
        for d in g["domains"] if d not in off}
check("routed is exactly the ticked groups less the exceptions",
      routed == want, str(sorted(routed ^ want)))
check("every exception is out of it", not (routed & off), str(sorted(routed & off)))
check("and nothing is in both lists", not (routed & bypassed),
      str(sorted(routed & bypassed)))

# The conf the relay would write, built the way apply_profiles builds it.
me = "198.51.100.1"
body = ["address=/%s/%s" % (d, me) for d in sorted(routed)]
body += ["server=/%s/1.1.1.1" % d for d in sorted(bypassed)]
conf = chr(10).join(body)
for d in sorted(bypassed):
    if ("address=/%s/" % d) in conf:
        check("no hijack rule survives for %s" % d, False, conf[:200])
        break
else:
    check("no domain it must not route has a hijack rule", True)
one = sorted(routed)[0] if routed else ""
check("and the ones it does route still have theirs",
      bool(one) and ("address=/%s/%s" % (one, me)) in conf)

print("the operator's own domains, inside a template")
# Added on the domains page, they live in the database rather than the
# catalogue file - and the template page, drawn from the catalogue alone,
# showed that service as having none while the relay routed them anyway.
for d in ("kmplayer.com", "example.org"):
    store.run("INSERT INTO custom_domains (domain, added_at) VALUES (?, ?)",
              (d, panel.now()))
store.run("UPDATE users SET template_id = ? WHERE phone = '09120000077'", (tid2,))
store.run("INSERT OR IGNORE INTO template_services"
          " (template_id, service_key, group_key) VALUES (?, 'custom', 'main')",
          (tid2,))
html_out = Page().templates()
drawer = html_out[html_out.index("value='custom.main'"):]
drawer = drawer[:drawer.index("</details>")]
check("the template page lists them",
      "kmplayer.com" in drawer and "example.org" in drawer, drawer[:400])
check("ticked, since the template routes them",
      "value='kmplayer.com' checked" in drawer, drawer[:400])
check("and counted", "2 از 2 دامنه" in drawer, drawer[:400])

rec3 = Recorder()
rec3.action("template-save", {
    "id": [str(tid2)], "g": ["spotify.main", "custom.main"],
    "d": ["scdn.co", "spotify.com", "spotifycdn.com", "example.org"],
})
check("un-ticking one is stored like any other exception",
      store.template_domains_off(tid2) == {"kmplayer.com"},
      str(store.template_domains_off(tid2)))
_, profs = store.profiles(CATALOGUE, default)
custom = profs[str(tid2)]["custom"]
check("and the relay is not told to route it", "kmplayer.com" not in custom,
      str(custom))
check("while the one left ticked still routes", "example.org" in custom,
      str(custom))

store.run("INSERT INTO custom_domains (domain, added_at) VALUES (?, ?)",
          ("added-later.net", panel.now()))
_, profs = store.profiles(CATALOGUE, default)
check("one added later routes without re-saving the template",
      "added-later.net" in profs[str(tid2)]["custom"],
      str(profs[str(tid2)]["custom"]))

rec4 = Recorder()
rec4.action("template-save", {"id": [str(tid2)], "g": ["spotify.main"],
                              "d": ["scdn.co", "spotify.com", "spotifycdn.com"]})
_, profs = store.profiles(CATALOGUE, default)
check("the whole service un-ticked routes none of them",
      profs[str(tid2)]["custom"] == [], str(profs[str(tid2)]["custom"]))

shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
