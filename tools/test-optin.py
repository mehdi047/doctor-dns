#!/usr/bin/env python3
"""Opt-in groups: visible in the panel, routed by nobody until ticked.

Epic's game backend is the first of them. Routing it breaks Fortnite
matchmaking, so it belongs in the catalogue where an operator can see it and
decide - but a group that arrives already switched on has decided for them, in
the direction that breaks something.

Two things have to hold and neither is obvious. The default template means
"everything, now and later", so it has to be taught this one exception. And
epic-pin writes rules naming those exact hosts, which outrank any rule that
routes the parent domain - so a template that ticks the group has to have
those pins left out of it, or the tick does nothing at all.
"""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import sys
import tempfile

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
sync = load("smartdns-sync", "sync")

print("the catalogue that ships")
cat = json.load(open(os.path.join(HERE, "..", "domains", "services.json"),
                     encoding="utf-8"))["services"]
epic = next(s for s in cat if s["key"] == "epic")
groups = {g["key"]: g for g in epic["groups"]}
check("Epic has a store group and a backend group",
      set(groups) == {"main", "backend"}, str(set(groups)))
check("the store group is ordinary", not groups["main"].get("opt_in"))
check("the backend group is opt-in", groups["backend"].get("opt_in") is True)
check("it holds the hosts epic-pin pins",
      len(groups["backend"]["domains"]) >= 15,
      str(len(groups["backend"]["domains"])))
check("and they are the same hosts",
      "fortnite-public-service-prod11.ol.epicgames.com"
      in groups["backend"]["domains"])

pinned = open(os.path.join(HERE, "..", "templates", "epic-pin"),
              encoding="utf-8").read()
missing = [d for d in groups["backend"]["domains"] if d not in pinned]
check("every catalogued backend host is one epic-pin knows",
      not missing, str(missing[:3]))

print("no template routes it by accident")
tmp = tempfile.mkdtemp()
store = panel.Store(os.path.join(tmp, "panel.db"))
default = store.ensure_default_template(cat)["id"]

backend = set(groups["backend"]["domains"])
bypass = set(store.bypass_for(default, cat))
check("the default template does not route it",
      backend <= bypass, str(sorted(backend - bypass)[:2]))
check("but the default still routes everything else",
      "epicgames.com" not in bypass and "spotify.com" not in bypass,
      str(sorted(bypass - backend)[:3]))

cur = store.run("INSERT INTO templates (name, is_default, created_at)"
                " VALUES ('تازه', 0, ?)", (panel.now(),))
fresh = cur.lastrowid
for svc in cat:
    for g in svc["groups"]:
        store.run("INSERT INTO template_services (template_id, service_key,"
                  " group_key) VALUES (?, ?, ?)", (fresh, svc["key"], g["key"]))
store.run("DELETE FROM template_services WHERE template_id = ? AND"
          " service_key = 'epic' AND group_key = 'backend'", (fresh,))
check("a template that ticked everything but this does not route it",
      backend <= set(store.bypass_for(fresh, cat)))

print("a template that does tick it, routes it")
store.run("INSERT INTO template_services (template_id, service_key, group_key)"
          " VALUES (?, 'epic', 'backend')", (fresh,))
check("it is no longer bypassed",
      not (backend & set(store.bypass_for(fresh, cat))))

print("and the relay is told to drop the pins for exactly that template")
# A template only becomes a profile once somebody is actually on it - an
# unused template costs a resolver on every relay for nobody.
store.run("INSERT INTO users (phone, first_name, created_at, template_id)"
          " VALUES ('09120000001', 'کاربر', ?, ?)", (panel.now(), fresh))
store.run("INSERT INTO ips (user_id, ip, added_at)"
          " VALUES ((SELECT id FROM users WHERE phone='09120000001'),"
          " '198.51.100.5', ?)", (panel.now(),))
by_ip, profiles = store.profiles(cat, default)
check("the ticking template asks for no pins",
      profiles[str(fresh)]["pins"] is False, str(profiles.get(str(fresh), {}).get("pins")))

store.run("DELETE FROM template_services WHERE template_id = ? AND"
          " service_key = 'epic' AND group_key = 'backend'", (fresh,))
_, profiles = store.profiles(cat, default)
check("a template that has not ticked it keeps them",
      profiles[str(fresh)]["pins"] is True)

print("a template made in the panel does not tick it either")
adm_spec = importlib.util.spec_from_loader(
    "admin", importlib.machinery.SourceFileLoader(
        "admin", os.path.join(HERE, "..", "templates", "smartdns-admin")))
admin = importlib.util.module_from_spec(adm_spec)
adm_spec.loader.exec_module(admin)
admin.STORE = admin.Store(os.path.join(tmp, "panel.db"))
admin.CATALOGUE = cat
admin.CFG = {"ADMIN_PATH": "p"}


class Rec:
    def __init__(self):
        self._headers_buffer = []
        self.sent = {}

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
    wfile = _W()


for n in ("action", "redirect", "send"):
    setattr(Rec, n, getattr(admin.Admin, n))
Rec.one = staticmethod(admin.Admin.one)

Rec().action("template-new", {"name": ["از پنل"]})
made = store.one("SELECT id FROM templates WHERE name = 'از پنل'")
check("the template was created", made is not None)
ticks = store.template_groups(made["id"])
check("it ticked the ordinary groups", ("epic", "main") in ticks)
check("it did NOT tick the opt-in one", ("epic", "backend") not in ticks,
      str(sorted(t for t in ticks if t[0] == "epic")))
check("so it does not route the backend",
      backend <= set(store.bypass_for(made["id"], cat)))

print("nor does the default template carry a tick nobody made")
check("the default has no opt-in row",
      ("epic", "backend") not in store.template_groups(default))

print("the relay writes them accordingly")
pins_file = os.path.join(tmp, "epic-pins.conf")
open(pins_file, "w", newline="\n").write(
    "# generated by epic-pin\n"
    "address=/fortnite-public-service-prod11.ol.epicgames.com/104.18.12.27\n"
    "address=/ds.svc.live.fngw.ol.epicgames.com/104.18.7.216\n")
sync.EPIC_PINS = pins_file
lines = sync.epic_pin_lines()
check("it reads the pins", len(lines) == 2, str(lines))
check("and skips the comment", all(l.startswith("address=") for l in lines))

sync.EPIC_PINS = os.path.join(tmp, "not-there.conf")
check("a relay with no pins file copes", sync.epic_pin_lines() == [])

print("the pins are kept out of the shared mirror")
src = open(os.path.join(HERE, "..", "templates", "smartdns-sync"),
           encoding="utf-8").read()
mirror = src[src.index("def sync_base_dir"):]
mirror = mirror[:mirror.index("return changed")]
check("sync_base_dir excludes them", "EPIC_PINS" in mirror, mirror[:200])
check("as it already does the custom domains", "CUSTOM_CONF" in mirror)

print("the panel warns before somebody ticks it")
adm = open(os.path.join(HERE, "..", "templates", "smartdns-admin"),
           encoding="utf-8").read()
check("the editor marks opt-in groups", 'g.get("opt_in")' in adm)
check("and says what turning it on costs", "matchmaking" in adm)
check("the default template's page explains the exception",
      "پیش‌فرض خاموش" in adm)

shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
