#!/usr/bin/env python3
"""Per-customer speed limits: from the panel's answer to the shaper's input.

What matters is the chain, not any one link. A number typed in the panel has to
survive into the sync answer, be turned into the right shaping request, and
stop being sent the moment the limit is lifted - and the agent must not call
tc thirty times a minute to restate what the kernel already knows.

The tc calls themselves are checked against a stub. Whether htb actually
shapes is not something a unit test can answer; that was measured on the relay.
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
shape = load("smartdns-shape", "shape")
sync = load("smartdns-sync", "sync")

CATALOGUE = [{"key": "spotify", "label": "Spotify", "groups": [
    {"key": "main", "label": "همه", "domains": ["spotify.com"]}]}]

tmp = tempfile.mkdtemp()
store = panel.Store(os.path.join(tmp, "panel.db"))
default = store.ensure_default_template(CATALOGUE)["id"]

print("the column arrives on an existing database and defaults to no limit")
cols = {r[1]: r for r in store.db.execute("PRAGMA table_info(users)")}
check("speed_kbps exists", "speed_kbps" in cols)
check("it defaults to zero", "0" in str(cols["speed_kbps"][4]), str(cols.get("speed_kbps")))

store.run("INSERT INTO users (telegram_id, first_name, created_at)"
          " VALUES (11, 'unlimited', ?)", (panel.now(),))
store.run("INSERT INTO users (telegram_id, first_name, created_at, speed_kbps)"
          " VALUES (22, 'capped', ?, 8000)", (panel.now(),))
store.run("INSERT INTO ips (user_id, ip, added_at) VALUES (1, '198.51.100.5', ?)",
          (panel.now(),))
store.run("INSERT INTO ips (user_id, ip, added_at) VALUES (2, '198.51.100.16', ?)",
          (panel.now(),))

print("the sync answer carries it")
by_ip, profiles = store.profiles(CATALOGUE, default)
allowed = [{"ip": ip, "name": "u%d" % v["uid"], "uid": v["uid"],
            "kbps": v["kbps"]} for ip, v in sorted(by_ip.items())]
check("the capped customer's speed is in the answer",
      {a["ip"]: a["kbps"] for a in allowed} == {"198.51.100.5": 0, "198.51.100.16": 8000},
      str(allowed))
check("the mark is the account number",
      {a["ip"]: a["uid"] for a in allowed} == {"198.51.100.5": 1, "198.51.100.16": 2},
      str(allowed))

print("the agent turns that into one shaping request, and only when it changes")
calls = []


class FakeRun:
    def __init__(self, rc=0, out=""):
        self.returncode, self.stdout, self.stderr = rc, out, ""


sync.SHAPE = os.path.join(HERE, "..", "templates", "smartdns-shape")
sync.subprocess = type("S", (), {
    "run": staticmethod(lambda *a, **kw: (calls.append(kw.get("input")),
                                          FakeRun())[1])})()
sync.SHAPED = None

sync.apply_speeds(allowed)
check("one call was made", len(calls) == 1, "%d calls" % len(calls))
check("only the limited customer is sent",
      json.loads(calls[0]) == [{"ip": "198.51.100.16", "mark": 2, "kbps": 8000}],
      calls[0] if calls else "")

sync.apply_speeds(allowed)
check("an unchanged pass calls nothing", len(calls) == 1, "%d calls" % len(calls))

# By account, not by position: the list is sorted by address, and which end
# the capped customer lands on depends on how their address happens to sort.
capped = next(a for a in allowed if a["uid"] == 2)
capped["kbps"] = 20000
sync.apply_speeds(allowed)
check("a changed speed is sent", len(calls) == 2 and
      json.loads(calls[1])[0]["kbps"] == 20000, str(calls[-1:]))

capped["kbps"] = 0
sync.apply_speeds(allowed)
check("lifting the limit sends an empty list",
      len(calls) == 3 and json.loads(calls[2]) == [], str(calls[-1:]))

print("the shaper builds the right tc commands")
ran = []


def fake_run(*args, **kw):
    ran.append(list(args))
    if args[0] == "ip":
        return FakeRun(0, "1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.5 uid 0 \n")
    if args[:3] == ("tc", "-j", "qdisc"):
        return FakeRun(0, json.dumps([{"kind": "htb", "handle": "1:"}]))
    if args[:3] == ("tc", "-j", "class"):
        # One customer already shaped at 8 Mbit, one stale class to clear.
        # Customer classes sit at CLASS_BASE + mark: mark 2 is 1:102, mark 9
        # is 1:109. 1:1 is the root class every one of them hangs under, and a
        # customer must never land on it.
        return FakeRun(0, json.dumps([
            {"handle": "1:1", "rate": 10000000000},
            {"handle": "1:ffff", "rate": 10000000000},
            {"handle": "1:102", "rate": 8000000},
            {"handle": "1:109", "rate": 1000000}]))
    return FakeRun(0, "")


shape.run = fake_run
shape.apply_wanted([{"ip": "198.51.100.16", "mark": 2, "kbps": 20000},
                    {"ip": "198.51.100.27", "mark": 3, "kbps": 5000}])
flat = [" ".join(c) for c in ran]

check("the existing class is re-rated, not duplicated",
      any("class replace" in f and "1:102" in f and "20000kbit" in f for f in flat),
      "\n".join(flat))
check("the new customer gets a class",
      any("class replace" in f and "1:103" in f and "5000kbit" in f for f in flat))
check("the filter is keyed on the mark, and points at the class",
      any("filter add" in f and "handle 3 fw" in f and "flowid 1:103" in f
          for f in flat), "\n".join(flat))
check("each class gets fq_codel under it",
      any("qdisc replace" in f and "parent 1:103" in f and "fq_codel" in f
          for f in flat))
check("the stale class is removed",
      any("class del" in f and "1:109" in f for f in flat), "\n".join(flat))
check("the stale filter is removed first",
      any("filter del" in f and "handle 9 fw" in f for f in flat))
check("the root is not rebuilt when it already exists",
      not any("qdisc replace" in f and "root" in f for f in flat), "\n".join(flat))
check("the address map is flushed then filled",
      any("flush map inet smartdns speed" in f for f in flat) and
      any("add element inet smartdns speed" in f and "198.51.100.16 : 2" in f
          and "198.51.100.27 : 3" in f for f in flat), "\n".join(flat))

print("the very first customer does not land on the root")
# mark 1 is what the first customer a service ever shapes gets. It used to
# become class 1:1 - the root class every customer class hangs under - and
# leaf qdisc handle 1:, which is the root qdisc's own handle. tc refused the
# qdisc every thirty seconds, and the class that did get created replaced the
# root, quietly capping the whole relay at that one customer's speed.
ran.clear()
shape.apply_wanted([{"ip": "198.51.100.1", "mark": 1, "kbps": 16000}])
first = [" ".join(c) for c in ran]
check("its class is not the root class",
      not any("classid 1:1 " in f for f in first), "\n".join(first))
check("nor is its leaf qdisc the root qdisc's handle",
      not any("handle 1: fq_codel" in f for f in first), "\n".join(first))
check("it gets a class of its own",
      any("class replace" in f and "1:101" in f and "16000kbit" in f
          for f in first), "\n".join(first))
check("with fq_codel under it",
      any("qdisc replace" in f and "parent 1:101" in f and "fq_codel" in f
          for f in first))
check("and the filter still carries the raw mark",
      any("handle 1 fw" in f and "flowid 1:101" in f for f in first))
check("no mark can reach the default class",
      shape.minor_for(shape.MAX_MARK) < shape.DEFAULT_MINOR,
      "%#x vs %#x" % (shape.minor_for(shape.MAX_MARK), shape.DEFAULT_MINOR))

print("the shaper refuses what it cannot mark")
for bad, why in [([{"ip": "1.1.1.1", "mark": 0, "kbps": 100}], "mark 0"),
                 ([{"ip": "1.1.1.1", "mark": 65535, "kbps": 100}], "the default class"),
                 ([{"ip": "1.1.1.1", "mark": 2, "kbps": 1},
                   {"ip": "198.51.100.2", "mark": 2, "kbps": 1}], "a repeated mark")]:
    try:
        shape.apply_wanted(bad)
        check("refuses %s" % why, False, "it was accepted")
    except SystemExit:
        check("refuses %s" % why, True)

print("no limits at all puts the interface back as the kernel had it")
ran.clear()
shape.apply_wanted([])
flat = [" ".join(c) for c in ran]
check("every class is torn down",
      all(any("class del" in f and "1:%x" % shape.minor_for(m) in f
              for f in flat) for m in (2, 9)),
      "\n".join(flat))
check("the htb root is removed too",
      any("qdisc del" in f and "root" in f for f in flat), "\n".join(flat))
check("the map is emptied",
      any("flush map" in f for f in flat) and
      not any("add element" in f for f in flat), "\n".join(flat))

print("a relay that has never shaped anybody is left completely alone")
ran.clear()


def no_classes(*args, **kw):
    ran.append(list(args))
    if args[0] == "ip":
        return FakeRun(0, "1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.5 uid 0 \n")
    if args[:3] == ("tc", "-j", "class"):
        return FakeRun(0, "[]")
    return FakeRun(0, "")


shape.run = no_classes
shape.apply_wanted([])
flat = [" ".join(c) for c in ran]
check("no qdisc is created", not any("qdisc replace" in f for f in flat),
      "\n".join(flat))
check("no qdisc is deleted either", not any("qdisc del" in f for f in flat),
      "\n".join(flat))

shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
