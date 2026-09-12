#!/usr/bin/env python3
"""smartdns-restart: one command that restarts every part of a machine."""
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
TOOL = os.path.join(HERE, "..", "templates", "smartdns-restart")
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


# The real script, against a machine laid out in a temporary directory, with
# the system commands it calls answered by stand-ins that write down what they
# were asked to do.
tmp = tempfile.mkdtemp()
fake = os.path.join(tmp, "bin")
os.makedirs(fake)
CALLS = os.path.join(tmp, "calls")


def tool(name, body):
    p = os.path.join(fake, name)
    with open(p, "w", newline="\n") as fh:
        fh.write("#!/bin/bash\n" + body + "\n")
    os.chmod(p, 0o755)


tool("id", 'echo "${FAKE_UID:-0}"')
tool("sleep", "exit 0")
# Every unit is installed and running, except those named in FAKE_MISSING
# (not installed) and FAKE_DOWN (will not stay up).
tool("systemctl", r'''
echo "systemctl $*" >> "$CALLS"
case "$1" in
  show)      u="${@: -1}"
             case " $FAKE_MISSING " in *" $u "*) echo not-found ;; *) echo loaded ;; esac ;;
  is-active) case " $FAKE_DOWN " in *" $2 "*) echo failed ;; *) echo active ;; esac ;;
esac
exit 0''')
tool("nginx", '[ -n "$FAKE_NGINX_BROKEN" ] && { echo "nginx: [emerg] unexpected }" >&2; exit 1; }; exit 0')
tool("dnsmasq", "exit 0")


def machine(role, profiles=(), **env):
    etc = tempfile.mkdtemp(dir=tmp)
    with open(os.path.join(etc, "sync.env" if role == "relay" else "panel.env"), "w") as fh:
        fh.write("X=1\n")
    prof = tempfile.mkdtemp(dir=tmp)
    for p in profiles:
        open(os.path.join(prof, p + ".conf"), "w").close()
    if os.path.exists(CALLS):
        os.remove(CALLS)
    e = dict(os.environ, PATH=posix(fake) + ":" + os.environ.get("PATH", ""),
             SMARTDNS_ETC=posix(etc), SMARTDNS_PROFILES=posix(prof), CALLS=posix(CALLS),
             FAKE_UID="0", FAKE_MISSING="", FAKE_DOWN="", FAKE_NGINX_BROKEN="")
    e.update(env)
    r = subprocess.run([BASH, posix(TOOL)], capture_output=True, text=True,
                       timeout=60, env=e)
    calls = open(CALLS).read() if os.path.exists(CALLS) else ""
    restarted = [l.split()[2:] for l in calls.splitlines() if l.split()[1:2] == ["restart"]]
    return r, [u for group in restarted for u in group], restarted


print("the command itself")
check("it parses", subprocess.run([BASH, "-n", posix(TOOL)],
                                  capture_output=True).returncode == 0)
r = subprocess.run([BASH, posix(TOOL), "-h"], capture_output=True, text=True)
check("-h explains it, without needing root",
      r.returncode == 0 and "smartdns-restart" in r.stdout, r.stdout + r.stderr)
check("a wrong option is refused",
      subprocess.run([BASH, posix(TOOL), "--bogus"], capture_output=True).returncode != 0)
r, done, _ = machine("relay", FAKE_UID="1000")
check("it wants root", r.returncode != 0 and "sudo" in r.stderr and not done)

print("on a relay")
r, done, groups = machine("relay", profiles=("p1", "p2"))
check("everything comes back and it says so",
      r.returncode == 0 and "all of it is back up" in r.stdout, r.stdout + r.stderr)
check("it restarts the sync agent, both resolvers, dnsmasq, coturn and nginx",
      sorted(done) == sorted(["smartdns-sync", "smartdns-dns@p1", "smartdns-dns@p2",
                              "dnsmasq", "coturn", "nginx"]), str(done))
check("each resolver once, in the same call as the agent they belong to",
      ["smartdns-sync", "smartdns-dns@p1", "smartdns-dns@p2"] in groups, str(groups))
check("nftables is never touched - it holds the allowlist",
      "nftables" not in open(CALLS).read())
check("it warns that connections drop for a moment", "drop for a moment" in r.stdout)
check("a unit that failed too often is forgiven first",
      "systemctl reset-failed nginx" in open(CALLS).read())

r, done, _ = machine("relay", FAKE_NGINX_BROKEN="1")
check("a broken nginx config: nginx is left running, not restarted", "nginx" not in done)
check("the rest still restart", "dnsmasq" in done and "smartdns-sync" in done, str(done))
check("and it says why, and fails",
      r.returncode != 0 and "unexpected }" in r.stdout and "not restarted" in r.stdout,
      r.stdout)

r, done, _ = machine("relay", FAKE_DOWN="coturn")
check("a service that does not come back is named, and the command fails",
      r.returncode != 0 and "coturn" in r.stdout and "failed" in r.stdout
      and "smartdns-logs -e" in r.stdout, r.stdout)

print("on an exit")
r, done, _ = machine("exit")
check("it restarts both panels and nginx",
      r.returncode == 0 and sorted(done) == ["nginx", "smartdns-admin", "smartdns-panel"],
      str(done) + r.stdout + r.stderr)
check("with no connection warning - no customer's traffic is cut there",
      "drop for a moment" not in r.stdout)
r, done, _ = machine("exit", FAKE_MISSING="smartdns-admin")
check("an exit without an admin panel skips it quietly",
      r.returncode == 0 and "smartdns-admin" not in done
      and "smartdns-admin" not in r.stdout, r.stdout)

r = subprocess.run([BASH, posix(TOOL)], capture_output=True, text=True, timeout=60,
                   env=dict(os.environ, PATH=posix(fake) + ":" + os.environ.get("PATH", ""),
                            SMARTDNS_ETC=posix(tempfile.mkdtemp(dir=tmp)), FAKE_UID="0",
                            CALLS=posix(CALLS)))
check("a machine without doctor dns is told so", r.returncode != 0
      and "not installed" in r.stderr, r.stderr)
shutil.rmtree(tmp, ignore_errors=True)

print("the installer puts it on both machines")
built = open(BUILT, encoding="utf-8").read()
at = built.find("payload SMARTDNS_RESTART > /usr/local/bin/smartdns-restart")
check("the installer writes it", at > 0)
check("with a domain or without",
      0 < at < built.index('if [ -n "${PANEL_DOMAIN:-}" ]; then\n    step "HTTPS'))
check("and uninstall knows it is ours",
      "note_file /usr/local/bin/smartdns-restart" in built)

print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
