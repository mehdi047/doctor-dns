#!/usr/bin/env python3
"""smartdns-access: changing how the admin panel is reached.

Run against a throwaway admin.env with systemctl, ss and the panel stubbed
out, so what is checked is the decision-making - what it refuses, what it
writes, and whether the password ends up as a hash and never as itself.
"""
import os
import shutil
import subprocess
import sys
import tempfile

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "templates", "smartdns-access")
fails = []


def check(label, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + label +
          ((" - " + detail) if detail and not cond else ""))
    if not cond:
        fails.append(label)


if shutil.which("bash") is None:
    print("bash not available - skipping")
    sys.exit(0)

def posix(path):
    r"""A path bash will understand.

    On Windows the temp directory is C:\Users\..., and putting that inside a
    shell script makes bash read every backslash as an escape - which is how
    the first version of this test managed to fail twenty checks that were
    all really one broken path.
    """
    path = os.path.abspath(path)
    if len(path) > 1 and path[1] == ":":
        path = "/" + path[0].lower() + path[2:]
    return path.replace("\\", "/")


tmp = tempfile.mkdtemp()
conf = os.path.join(tmp, "admin.env")
binn = os.path.join(tmp, "bin")
os.makedirs(binn)

# Stubs for everything that would touch the machine. `id` reports root so the
# tool proceeds; systemctl reports the panel healthy; ss reports every port
# free unless a test says otherwise.
for name, body in [
        ("id", "#!/bin/sh\necho 0\n"),
        ("systemctl", "#!/bin/sh\nexit 0\n"),
        ("ss", "#!/bin/sh\nexit 0\n"),
        ("hostname", "#!/bin/sh\necho 198.51.100.9\n"),
        # Not a stub: the real interpreter, because hashing the password is
        # the part worth exercising. On Debian python3 is simply on PATH; in
        # git-bash on Windows it resolves to a Microsoft Store shim that
        # prints an advert and exits.
        ("python3", "#!/bin/sh\nexec '%s' \"$@\"\n" % posix(sys.executable))]:
    p = os.path.join(binn, name)
    open(p, "w", newline="\n").write(body)
    os.chmod(p, 0o755)


def fresh():
    open(conf, "w", newline="\n").write(
        "ADMIN_PORT=9443\n"
        "ADMIN_PATH=originalpath01\n"
        "ADMIN_SALT=00112233445566778899aabbccddeeff\n"
        "ADMIN_HASH=deadbeef\n"
        "ADMIN_CERT=/etc/letsencrypt/live/panel.example.com/fullchain.pem\n"
        "ADMIN_KEY=/etc/letsencrypt/live/panel.example.com/privkey.pem\n")


def run(*args, stdin=""):
    src = open(TOOL, encoding="utf-8").read().replace(
        "CONF=/etc/smart-dns/admin.env", "CONF=%s" % posix(conf))
    script = os.path.join(tmp, "tool")
    open(script, "w", newline="\n", encoding="utf-8").write(src)
    env = dict(os.environ, PATH=binn + os.pathsep + os.environ["PATH"])
    return subprocess.run(["bash", script] + list(args), input=stdin,
                          capture_output=True, text=True, env=env, timeout=60)


def value(key):
    for line in open(conf, encoding="utf-8"):
        if line.startswith(key + "="):
            return line.split("=", 1)[1].strip()
    return None


print("it shows where the panel answers")
fresh()
r = run("show")
check("prints the full address",
      "https://panel.example.com:9443/originalpath01/" in r.stdout, r.stdout)
check("takes the name from the certificate", "panel.example.com" in r.stdout)

print("changing the port")
fresh()
r = run("port", "9999")
check("accepted", r.returncode == 0, r.stdout + r.stderr)
check("written to the config", value("ADMIN_PORT") == "9999", str(value("ADMIN_PORT")))
check("the new address is shown", ":9999/" in r.stdout)

for bad, why in [("443", "the service's own https"), ("53", "dns"),
                 ("8443", "the sync API the relays use"), ("22", "ssh"),
                 ("0", "out of range"), ("70000", "out of range"),
                 ("abc", "not a number"), ("", "missing")]:
    fresh()
    r = run("port", bad) if bad else run("port")
    check("refuses %s (%s)" % (bad or "nothing", why),
          r.returncode != 0 and value("ADMIN_PORT") == "9443",
          (r.stdout + r.stderr).strip()[:90])

print("changing the path")
fresh()
r = run("path")
check("a generated one is accepted", r.returncode == 0, r.stderr)
check("it changed", value("ADMIN_PATH") != "originalpath01")
check("and is long enough to be unguessable", len(value("ADMIN_PATH")) >= 16,
      value("ADMIN_PATH"))

fresh()
r = run("path", "my-new-path_9")
check("an explicit one is accepted", r.returncode == 0, r.stderr)
check("it is used verbatim", value("ADMIN_PATH") == "my-new-path_9")

for bad, why in [("short", "too short"), ("has/slash", "a slash"),
                 ("has space", "a space"), ("bad?query", "a query mark")]:
    fresh()
    r = run("path", bad)
    check("refuses %r (%s)" % (bad, why),
          r.returncode != 0 and value("ADMIN_PATH") == "originalpath01",
          (r.stdout + r.stderr).strip()[:90])

print("changing the password")
fresh()
before_salt, before_hash = value("ADMIN_SALT"), value("ADMIN_HASH")
r = run("password", "correct horse battery")
check("accepted", r.returncode == 0, r.stdout + r.stderr)
check("the salt is new", value("ADMIN_SALT") != before_salt)
check("the hash is new", value("ADMIN_HASH") != before_hash)
check("the hash looks like pbkdf2 output", len(value("ADMIN_HASH")) == 64,
      value("ADMIN_HASH"))
check("the password itself is nowhere in the file",
      "correct horse battery" not in open(conf, encoding="utf-8").read())
check("it says sessions end", "signed out" in r.stdout, r.stdout)

fresh()
r = run("password", "short")
check("refuses a short password",
      r.returncode != 0 and value("ADMIN_HASH") == "deadbeef",
      (r.stdout + r.stderr).strip()[:90])

fresh()
r = run("password", stdin="onepassword\notherpassword\n")
check("refuses when the two typed do not match",
      r.returncode != 0 and value("ADMIN_HASH") == "deadbeef",
      (r.stdout + r.stderr).strip()[:90])

fresh()
r = run("password", stdin="typed-twice-ok\ntyped-twice-ok\n")
check("accepts when they match", r.returncode == 0 and
      value("ADMIN_HASH") != "deadbeef", (r.stdout + r.stderr)[:90])
check("what was typed is not echoed back",
      "typed-twice-ok" not in r.stdout, r.stdout)

print("rotate does both at once")
fresh()
r = run("rotate", "a-fresh-password")
check("the path changed", value("ADMIN_PATH") != "originalpath01")
check("the hash changed", value("ADMIN_HASH") != "deadbeef")
check("the new address is printed", "https://" in r.stdout)

print("it refuses to run where there is no panel")
os.unlink(conf)
r = run("show")
check("says so plainly", r.returncode != 0 and "no admin panel" in r.stderr,
      (r.stdout + r.stderr).strip()[:120])

# File modes are a POSIX idea; Windows reports 0o666 whatever chmod is told,
# so this one only means something where the code actually runs.
if os.name == "posix":
    print("the config keeps its permissions")
    fresh()
    os.chmod(conf, 0o600)
    run("port", "9500")
    check("still owner-only", (os.stat(conf).st_mode & 0o777) == 0o600,
          oct(os.stat(conf).st_mode & 0o777))

shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
