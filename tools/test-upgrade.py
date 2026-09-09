#!/usr/bin/env python3
"""Installing over an install: what it asks, and what it must not lose.

Re-running the installer is normal - it is how a machine is repaired and how
it is upgraded. Two things make it worth stopping to ask first. An upgrade
should be a decision rather than something discovered afterwards, and the
opposite case is the one that actually bites: an old file still sitting in a
home directory, run again months later, quietly putting old configs over new.

And whatever the answer, the customer database has to come through it. That
is the part with nothing to fall back on - configs are regenerated from the
script, certificates are re-issued, but the customers, their usage and their
addresses exist in exactly one file.
"""
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
BUILT = os.path.join(HERE, "..", "doctor-dns.sh")
fails = []


def check(label, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + label +
          ((" - " + detail) if detail and not cond else ""))
    if not cond:
        fails.append(label)


BASH = shutil.which("bash")
if BASH is None:
    print("bash not available - skipping")
    sys.exit(0)


def posix(path):
    path = os.path.abspath(path)
    if len(path) > 1 and path[1] == ":":
        path = "/" + path[0].lower() + path[2:]
    return path.replace("\\", "/")


src = open(BUILT, encoding="utf-8").read()
VERSION = re.search(r'^VERSION="([^"]+)"', src, re.M).group(1)
print("this file says it is version %s" % VERSION)
check("the version looks like one",
      re.match(r"^\d+\.\d+\.\d+$", VERSION) is not None, VERSION)

# The real block, lifted out with the handful of things it leans on. Running
# the whole installer is not an option here - it would install.
def section(name):
    """Where `# ---- <name>` starts in the script."""
    m = re.search(r"^# -+ %s$" % re.escape(name), src, re.M)
    assert m, name
    return m.start()


head = src[src.index("if [ -t 1 ]; then"):section("payloads")]
block = src[section("version"):section("questions")]
check("the version block was found", "snapshot_db" in block, block[:120])
check("it is before any question is asked",
      src.index('VERSION_FILE="$STATE_DIR/version"')
      < src.index("Which side is this machine"))
check("and before anything is installed",
      src.index('VERSION_FILE="$STATE_DIR/version"') < src.index("apt-get update"))

tmp = tempfile.mkdtemp()
state = os.path.join(tmp, "state")
backup = os.path.join(tmp, "backup")
os.makedirs(state)
harness = os.path.join(tmp, "version.sh")
open(harness, "w", newline="\n", encoding="utf-8").write(
    "#!/usr/bin/env bash\nset -euo pipefail\n"
    'VERSION="%s"\nSTAMP=fixed\n' % VERSION +
    'STATE_DIR="%s"\nBACKUP_DIR="%s"\n' % (posix(state), posix(backup)) +
    head +
    'info() { printf "    %s\\n" "$*"; }\n'
    'warn() { printf "    %s\\n" "$*"; }\n'
    'die()  { printf "ERROR: %s\\n" "$*" >&2; exit 1; }\n' +
    block + '\nprintf "REACHED-INSTALL\\n"\n')


def put_version(v):
    p = os.path.join(state, "version")
    if v is None:
        if os.path.exists(p):
            os.remove(p)
    else:
        open(p, "w", newline="\n").write(v + "\n")


def make_db(rows=3):
    p = os.path.join(state, "panel.db")
    if os.path.exists(p):
        os.remove(p)
    db = sqlite3.connect(p)
    db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, phone TEXT)")
    db.executemany("INSERT INTO users (phone) VALUES (?)",
                   [("0912000000%d" % i,) for i in range(rows)])
    db.commit()
    db.close()
    return p


class Ran:
    def __init__(self, r):
        self.returncode = r.returncode
        self.stdout = r.stdout.decode("utf-8", "replace")
        self.stderr = r.stderr.decode("utf-8", "replace")


def run(answer="", **env):
    e = dict(os.environ)
    e.update({k: str(v) for k, v in env.items()})
    # Bytes, not text: on Windows, text mode turns a bare newline into a
    # carriage return and a newline, and the script would then read an
    # answer with a carriage return glued to it - a failure belonging to
    # the test rather than to the script.
    return Ran(subprocess.run([BASH, posix(harness)], input=answer.encode(),
                              capture_output=True, timeout=120, env=e))


print("a machine with nothing on it is not asked anything")
put_version(None)
r = run()
out = r.stdout + r.stderr
check("it goes straight on", "REACHED-INSTALL" in out, out[-200:])
check("and says nothing about versions", "Version" not in out, out[-200:])

print("the same version is a re-run, not an upgrade")
put_version(VERSION)
r = run()
out = r.stdout + r.stderr
check("it goes on", "REACHED-INSTALL" in out, out[-300:])
check("and says it is repairing", "already at %s" % VERSION in out, out[-300:])

print("an older install is offered the upgrade")
put_version("0.1.0")
db = make_db()
r = run(answer="\n")            # just pressing enter
out = r.stdout + r.stderr
check("it names both versions", "0.1.0" in out and VERSION in out, out[-400:])
check("it says it is an upgrade", "upgrade this machine" in out, out[-400:])
check("it promises the data is kept",
      "customers, settings, certificates" in out, out[-400:])
check("enter alone means yes", "REACHED-INSTALL" in out, out[-400:])

print("and the database is copied before anything starts")
copies = [f for f in os.listdir(backup)] if os.path.isdir(backup) else []
check("a copy was written", copies == ["panel.db.fixed"], str(copies))
if copies:
    cp = sqlite3.connect(os.path.join(backup, copies[0]))
    check("the copy has the customers in it",
          cp.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 3)
    cp.close()
check("and the original is still there", os.path.exists(db))
orig = sqlite3.connect(db)
check("with its rows untouched",
      orig.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 3)
orig.close()

print("saying no changes nothing")
shutil.rmtree(backup, ignore_errors=True)
put_version("0.1.0")
r = run(answer="n\n")
out = r.stdout + r.stderr
check("it stops", "REACHED-INSTALL" not in out, out[-300:])
check("and says so", "Nothing was changed" in out, out[-300:])
check("no copy was taken either", not os.path.isdir(backup))
check("it exits cleanly, not as a failure", r.returncode == 0, str(r.returncode))

print("an older FILE over a newer install is the dangerous one")
put_version("9.9.9")
r = run(answer="\n")            # enter again
out = r.stdout + r.stderr
check("it says the file is older", "OLDER than what is installed" in out,
      out[-400:])
check("it warns what that costs", "no way to undo" in out, out[-400:])
check("it points at the newest", "releases" in out, out[-400:])
check("and enter alone means NO here", "REACHED-INSTALL" not in out, out[-400:])
check("nothing was changed", "Nothing was changed" in out, out[-300:])

print("but it can still be forced through by hand")
r = run(answer="y\n")
out = r.stdout + r.stderr
check("answering yes goes on", "REACHED-INSTALL" in out, out[-300:])

print("unattended, it takes the safe answer on its own")
put_version("0.1.0")
r = run(ASSUME_YES="1")
out = r.stdout + r.stderr
check("an upgrade proceeds", "REACHED-INSTALL" in out, out[-300:])
check("without waiting for anybody", "ASSUME_YES" in out, out[-300:])
put_version("9.9.9")
r = run(ASSUME_YES="1")
out = r.stdout + r.stderr
check("a downgrade does not", "REACHED-INSTALL" not in out, out[-300:])

print("the version is recorded only by a run that finished")
tail = src[src.index('if [ "$fail" = 0 ]; then'):]
tail = tail[:tail.index("else")]
check("it is written in the success branch",
      '> "$VERSION_FILE"' in tail, tail[:300])
check("and written nowhere else",
      src.count('> "$VERSION_FILE"') == 1,
      str(src.count('> "$VERSION_FILE"')))
check("the summary line says which version",
      "is installed and working, version" in tail)

print("uninstall takes the note with it")
un = src[src.index("uninstall() {"):]
un = un[:un.index("\ncase \"${1:-}\" in")]
check("it removes the version file", 'rm -f "$STATE_DIR/version"' in un)
check("and still leaves the database alone",
      "database left where it is" in un)

print("--version and --help answer without root")
# The first version of this compared against apt-get, which both flags come
# before anyway - so it passed while the script still told an ordinary user
# to go and find sudo before it would tell them its own version.
check("the flags are handled", "--version|-V" in src)
check("before the root check, not after",
      src.index("--version|-V") < src.index('[ "$(id -u)" = 0 ]'))
check("and --help too",
      src.index("--help|-h") < src.index('[ "$(id -u)" = 0 ]'))
check("neither is handled twice",
      src.count("--version|-V") == 1 and src.count("--help|-h") == 1,
      "%d %d" % (src.count("--version|-V"), src.count("--help|-h")))

shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
