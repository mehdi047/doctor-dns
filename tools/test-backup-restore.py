#!/usr/bin/env python3
"""Backup and restore from the web panel.

The interesting failures here are not in the happy path. A restore replaces
every customer in the system, so what has to be proved is that a file which is
not one of our backups gets refused, that the previous state is kept, and that
the swap itself works where it actually runs - across a mount point, which is
where the first version of this quietly failed.
"""
import importlib.machinery
import importlib.util
import os
import shutil
import sqlite3
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
admin = load("smartdns-admin", "admin")

tmp = tempfile.mkdtemp()
db_path = os.path.join(tmp, "panel.db")
admin.DB = db_path
admin.CFG = {"ADMIN_PATH": "p"}

store = panel.Store(db_path)
store.run("INSERT INTO users (telegram_id, first_name, created_at, used_bytes)"
          " VALUES (11, 'یک', ?, 500)", (panel.now(),))
store.run("INSERT INTO users (telegram_id, first_name, created_at, used_bytes)"
          " VALUES (22, 'دو', ?, 900)", (panel.now(),))
store.run("INSERT INTO ips (user_id, ip, added_at) VALUES (1, '198.51.100.5', ?)",
          (panel.now(),))
store.ensure_default_template([])
# Metrics are the rows a backup is supposed to leave behind.
for i in range(40):
    store.record_metrics("relay-%d" % (i % 3), {"cpu": 5.0, "load": 0.1})
store.db.close()

admin.STORE = admin.Store(db_path)

print("the backup is a real snapshot, without the metrics")
out = os.path.join(tmp, "backup.db")
admin.STORE.snapshot(out)
copy = sqlite3.connect(out)
check("it opens", copy.execute("PRAGMA integrity_check").fetchone()[0] == "ok")
check("customers are in it",
      copy.execute("SELECT count(*) FROM users").fetchone()[0] == 2)
check("their usage is in it",
      copy.execute("SELECT sum(used_bytes) FROM users").fetchone()[0] == 1400)
check("addresses are in it",
      copy.execute("SELECT count(*) FROM ips").fetchone()[0] == 1)
check("host metrics are left out",
      copy.execute("SELECT count(*) FROM metrics").fetchone()[0] == 0)
copy.close()
check("the live database still has its metrics",
      admin.STORE.one("SELECT count(*) c FROM metrics")["c"] == 40)

print("inspect_backup refuses what it should")
counts = admin.inspect_backup(out)
check("our own backup is accepted", counts["users"] == 2, str(counts))

junk = os.path.join(tmp, "junk.db")
with open(junk, "wb") as fh:
    fh.write(b"this is not a database at all, it is a jpeg with delusions")
try:
    admin.inspect_backup(junk)
    check("a non-database is refused", False, "it was accepted")
except Exception as e:
    check("a non-database is refused", True, str(e))

other = os.path.join(tmp, "other.db")
o = sqlite3.connect(other)
o.execute("CREATE TABLE notes (id INTEGER, body TEXT)")
o.commit()
o.close()
try:
    admin.inspect_backup(other)
    check("somebody else's database is refused", False, "it was accepted")
except ValueError as e:
    check("somebody else's database is refused", "missing" in str(e), str(e))

print("the upload parser finds the file in a multipart body")
b = "----boundary9931"
body = (("--%s\r\nContent-Disposition: form-data; name=\"file\";"
         " filename=\"b.db\"\r\nContent-Type: application/octet-stream\r\n\r\n"
         % b).encode() + b"SQLite payload\r\n" + ("--%s--\r\n" % b).encode())
got = admin.parse_upload(body, "multipart/form-data; boundary=%s" % b, "file")
check("the bytes come back exactly", got == b"SQLite payload", repr(got))
try:
    admin.parse_upload(body, "multipart/form-data; boundary=%s" % b, "nothere")
    check("a missing field is an error", False)
except ValueError:
    check("a missing field is an error", True)
try:
    admin.parse_upload(b"x", "application/x-www-form-urlencoded", "file")
    check("a non-upload is an error", False)
except ValueError:
    check("a non-upload is an error", True)

print("a restore across a mount point")
# rename() cannot cross a mount point even on the same filesystem, which is
# what PrivateTmp makes /tmp into on the real host. os.replace from a
# different directory is the shape that failed; the code now stages beside
# the database, so this is the check that it does.
elsewhere = tempfile.mkdtemp()
staged = os.path.join(elsewhere, "incoming.db")
shutil.copyfile(out, staged)
admin.STORE.run("DELETE FROM users WHERE telegram_id = 22")
check("the live database now differs from the backup",
      admin.STORE.one("SELECT count(*) c FROM users")["c"] == 1)

keep = db_path + ".before-restore-test"
admin.STORE.snapshot(keep)
admin.STORE.close()
os.replace(staged, db_path) if os.path.dirname(staged) == os.path.dirname(db_path) \
    else shutil.move(staged, db_path)
for suffix in ("-wal", "-shm"):
    try:
        os.unlink(db_path + suffix)
    except OSError:
        pass
admin.STORE = admin.Store(db_path)
check("the restored database has both customers back",
      admin.STORE.one("SELECT count(*) c FROM users")["c"] == 2)
check("the state before the restore was kept",
      sqlite3.connect(keep).execute("SELECT count(*) FROM users").fetchone()[0] == 1)

print("the panel's own restore stages beside the database")
# Windows refuses to replace a file another handle still has open, which the
# real host does not - but closing first is what both services do anyway.
admin.STORE.close()
src = os.path.join(elsewhere, "from-telegram.db")
shutil.copyfile(out, src)
panel.DB = db_path
p2 = panel.Store(db_path)
kept = p2.restore(src)
check("it did not raise on a path in another directory", os.path.exists(db_path))
check("it kept the previous state", os.path.exists(kept))
check("it cleaned up the file it was given", not os.path.exists(src))
check("no staging file left behind",
      not [f for f in os.listdir(os.path.dirname(db_path))
           if f.startswith(".restore-")],
      str(os.listdir(os.path.dirname(db_path))))

print("the settings page no longer offers the bot token")
src_text = open(os.path.join(HERE, "..", "templates", "smartdns-admin"),
                encoding="utf-8").read()
check("no bot_token field in the panel", "bot_token" not in src_text)
check("the backup card is there", "backup.db" in src_text)

shutil.rmtree(tmp, ignore_errors=True)
shutil.rmtree(elsewhere, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
