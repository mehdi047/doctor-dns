#!/usr/bin/env python3
"""Offline check of web signup: the migration, then the endpoints.

Runs against a throwaway database built with the pre-migration schema, so the
path an existing deployment takes is the one exercised - not the fresh-install
path, which never had the constraint in the first place.
"""
import importlib.machinery
import importlib.util
import os
import shutil
import sqlite3
import sys
import tempfile

# Windows consoles still default to cp1252, and half of these labels are Persian.
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

OLD_USERS = """
CREATE TABLE users (
    id             INTEGER PRIMARY KEY,
    telegram_id    INTEGER UNIQUE NOT NULL,
    username       TEXT,
    first_name     TEXT,
    created_at     TEXT NOT NULL,
    status         TEXT NOT NULL DEFAULT 'active',
    quota_bytes    INTEGER NOT NULL DEFAULT 0,
    quota_mode     TEXT NOT NULL DEFAULT 'monthly',
    quota_reset_at TEXT,
    used_bytes     INTEGER NOT NULL DEFAULT 0,
    max_ips        INTEGER NOT NULL DEFAULT 1,
    wallet         INTEGER NOT NULL DEFAULT 0,
    warned         INTEGER NOT NULL DEFAULT 0,
    template_id    INTEGER REFERENCES templates(id)
);
"""

fails = []


def check(label, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + label + (" - " + detail if detail and not cond else ""))
    if not cond:
        fails.append(label)


tmp = tempfile.mkdtemp()
db_path = os.path.join(tmp, "panel.db")

print("building a pre-migration database")
raw = sqlite3.connect(db_path)
raw.executescript(panel.SCHEMA.replace(
    panel.SCHEMA[panel.SCHEMA.index("CREATE TABLE IF NOT EXISTS users ("):
                 panel.SCHEMA.index("-- One row per registered address")], ""))
raw.executescript(OLD_USERS)
raw.execute("INSERT INTO users (telegram_id, first_name, created_at, used_bytes)"
            " VALUES (100000001, 'کاربر قدیمی', '2026-09-01T00:00:00+00:00', 12345)")
raw.execute("INSERT INTO ips (user_id, ip, added_at) VALUES (1, '203.0.113.9', '2026-09-01T00:00:00+00:00')")
raw.execute("INSERT INTO transactions (user_id, amount, kind, created_at)"
            " VALUES (1, 5000, 'card', '2026-09-01T00:00:00+00:00')")
raw.commit()
raw.close()

print("opening it with the new code (migration should run)")
store = panel.Store(db_path)

cols = {r[1]: r for r in store.db.execute("PRAGMA table_info(users)")}
check("telegram_id is nullable", cols["telegram_id"][3] == 0)
check("phone column exists", "phone" in cols)
check("password_hash column exists", "password_hash" in cols)
check("template_id survived the rebuild", "template_id" in cols)
check("warned survived the rebuild", "warned" in cols)
check("the existing user is still there",
      store.one("SELECT * FROM users WHERE telegram_id = 100000001") is not None)
check("their usage survived",
      store.one("SELECT used_bytes u FROM users WHERE id = 1")["u"] == 12345)
check("their address survived",
      store.one("SELECT ip FROM ips WHERE user_id = 1")["ip"] == "203.0.113.9")
check("their transaction survived",
      store.one("SELECT 1 x FROM transactions WHERE user_id = 1") is not None)
check("no dangling references",
      not store.db.execute("PRAGMA foreign_key_check").fetchall())
check("a backup was written", os.path.exists(db_path + ".pre-websignup"))
check("telegram_id is still unique",
      any("telegram_id" in (r[0] or "") for r in store.db.execute(
          "SELECT sql FROM sqlite_master WHERE type='index' AND tbl_name='users'")
          ) or "UNIQUE" in store.one(
          "SELECT sql FROM sqlite_master WHERE name='users'")["sql"])

print("re-opening: the migration must not run twice")
store2 = panel.Store(db_path)
check("second open is a no-op",
      store2.one("SELECT COUNT(*) c FROM users")["c"] == 1)

print("phone normalisation")
for raw_in, want in [("09123456789", "09123456789"),
                     ("9123456789", "09123456789"),
                     ("+989123456789", "09123456789"),
                     ("0098 912 345 6789", "09123456789"),
                     ("۰۹۱۲۳۴۵۶۷۸۹", "09123456789"),
                     ("0912-345-6789", "09123456789"),
                     ("021 88776655", ""),
                     ("", ""),
                     ("abc", "")]:
    got = panel.normal_phone(raw_in)
    check("normal_phone(%r) -> %r" % (raw_in, want), got == want, "got %r" % got)


class FakeHandler:
    """Just enough of the API handler to call the endpoint methods."""
    def __init__(self, store):
        self.store = store


api = FakeHandler(store)
for name in ("do_user_signup", "do_user_password_login", "do_user_claim",
             "do_user_info", "do_claim_register", "_session_user"):
    setattr(FakeHandler, name, getattr(panel.API, name))

CATALOGUE = panel.load_catalogue() + [panel.CUSTOM_SERVICE]
DEFAULT = store.ensure_default_template(CATALOGUE)["id"]

print("signup")
res = api.do_user_signup({"phone": "۰۹۱۲۱۱۱۲۲۳۳", "password": "hunter2!!",
                          "name": "علی", "ip": "198.51.100.5"})
check("signup succeeds", res.get("ok"), str(res))
session = res.get("session", "")
check("signup returns a session", bool(session))
u = store.user_by_phone("09121112233")
check("account exists with a null telegram_id", u and u["telegram_id"] is None)
check("account got the trial allowance",
      u["quota_bytes"] == int(store.setting("trial_bytes")), str(u["quota_bytes"]))
check("the trial is 500 MB", u["quota_bytes"] == 500 * 1024 * 1024)
check("the trial runs at full speed", (u["speed_kbps"] or 0) == 0)
check("the trial has an end date", bool(u["expires_at"]), str(u["expires_at"]))
check("it does not renew itself", u["quota_mode"] == "oneoff", u["quota_mode"])
expires = panel.parse_ts(u["expires_at"])
hours = (expires - panel.datetime.now(panel.timezone.utc)).total_seconds() / 3600
check("it ends in about a day", 23 < hours <= 24.1, "%.1f hours" % hours)
check("no address registered yet", not store.user_ips(u["id"]))

check("short password refused",
      not api.do_user_signup({"phone": "09121112244", "password": "short",
                              "ip": "198.51.100.6"}).get("ok"))
check("bad phone refused",
      not api.do_user_signup({"phone": "12345", "password": "hunter2!!",
                              "ip": "198.51.100.7"}).get("ok"))
check("duplicate phone refused",
      not api.do_user_signup({"phone": "0912 111 2233", "password": "hunter2!!",
                              "ip": "198.51.100.8"}).get("ok"))

print("the address page's button")
res = api.do_user_claim({"session": session, "ip": "203.0.113.80"})
check("address registered", res.get("ok"), str(res))
check("it is on the account",
      store.user_ips(u["id"])[0]["ip"] == "203.0.113.80")
res = api.do_user_claim({"session": session, "ip": "203.0.113.9"})
check("an address owned by somebody else is refused", not res.get("ok"), str(res))

print("the trial ends on its date even with allowance left")
store.run("UPDATE users SET expires_at = ? WHERE id = ?",
          ((panel.datetime.now(panel.timezone.utc)
            - panel.timedelta(minutes=1)).isoformat(timespec="seconds"), u["id"]))
panel.enforce_quotas(store)
after = store.user_by_phone("09121112233")
check("the account is marked expired", after["status"] == "expired", after["status"])
check("an expired account is not in the allowlist",
      "203.0.113.80" not in dict(store.profiles(CATALOGUE, DEFAULT)[0]),
      str(store.profiles(CATALOGUE, DEFAULT)[0]))
store.run("UPDATE users SET status = 'active', expires_at = ? WHERE id = ?",
          ((panel.datetime.now(panel.timezone.utc)
            + panel.timedelta(days=1)).isoformat(timespec="seconds"), u["id"]))
panel.enforce_quotas(store)
check("an unexpired account is left alone",
      store.user_by_phone("09121112233")["status"] == "active")


print("login")
check("right password works",
      api.do_user_password_login({"phone": "09121112233",
                                  "password": "hunter2!!",
                                  "ip": "198.51.100.16"}).get("ok"))
bad = api.do_user_password_login({"phone": "09121112233", "password": "wrong",
                                  "ip": "198.51.100.16"})
check("wrong password refused", not bad.get("ok"))
unknown = api.do_user_password_login({"phone": "09129999999", "password": "wrong",
                                      "ip": "198.51.100.17"})
check("unknown number gives the same message as a wrong password",
      unknown.get("message") == bad.get("message"))

print("throttling")
panel.THROTTLE.clear("login:198.51.100.27")
for _ in range(8):
    api.do_user_password_login({"phone": "09121112233", "password": "no",
                                "ip": "198.51.100.27"})
blocked = api.do_user_password_login({"phone": "09121112233", "password": "no",
                                      "ip": "198.51.100.27"})
check("ninth attempt from one address is throttled",
      "دقیقه" in blocked.get("message", ""), str(blocked))
check("a different address is unaffected",
      api.do_user_password_login({"phone": "09121112233", "password": "hunter2!!",
                                  "ip": "198.51.100.28"}).get("ok"))

print("dashboard data")
info = api.do_user_info({"session": session, "ip": "203.0.113.80"})
check("info reads back", info.get("ok"), str(info))
check("info shows the address", info.get("ip") == "203.0.113.80")
check("info has no telegram id", info.get("telegram_id") is None)
check("info names the plan", bool(info.get("plan")))

print("the relay's allowlist still names every account")
by_ip, _ = store.profiles(CATALOGUE, DEFAULT)
check("web account appears in the allowlist", "203.0.113.80" in by_ip)
check("every entry can be labelled",
      all("u%d" % v["uid"] for v in by_ip.values()), str(by_ip))

print("nothing is left that needs a bot")
check("no Telegram client in the panel", not hasattr(panel, "Telegram"))
check("no bot class either", not hasattr(panel, "Bot"))
check("the config no longer demands a token",
      "BOT_TOKEN" not in open(
          os.path.join(HERE, "..", "templates", "smartdns-panel"),
          encoding="utf-8").read())

print("the customer's page carries the warning the bot used to send")
sync_spec = importlib.util.spec_from_loader(
    "sync", importlib.machinery.SourceFileLoader(
        "sync", os.path.join(HERE, "..", "templates", "smartdns-sync")))
sync = importlib.util.module_from_spec(sync_spec)
sync_spec.loader.exec_module(sync)

GB = 1024 ** 3
for state, warned, expect in [
        ({"status": "active", "quota": GB, "used": 0, "warned": 0}, None, ""),
        ({"status": "active", "quota": GB, "used": int(.85 * GB), "warned": 1},
         None, "۸۰"),
        ({"status": "active", "quota": GB, "used": int(.97 * GB), "warned": 3},
         None, "۹۵"),
        ({"status": "over_quota", "quota": GB, "used": GB, "warned": 3},
         None, "سهمیهٔ شما تمام شد"),
        ({"status": "expired", "quota": GB, "used": 0, "warned": 0},
         None, "دورهٔ آزمایشی شما تمام شد"),
        ({"status": "suspended", "quota": 0, "used": 0, "warned": 0},
         None, "غیرفعال")]:
    got = sync.account_notice(state)
    if expect:
        check("%s -> warns about %r" % (state["status"], expect[:22]),
              expect in got, got[:120])
    else:
        check("a healthy account gets no banner", got == "", got[:120])
check("only one banner at a time",
      sync.account_notice({"status": "active", "quota": GB,
                           "used": int(.97 * GB), "warned": 3}).count("<div") == 1)

shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
