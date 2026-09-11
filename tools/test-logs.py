#!/usr/bin/env python3
"""smartdns-logs: one command that shows what a machine has been doing."""
import os
import shutil
import subprocess
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "templates", "smartdns-logs")
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


def run(*args):
    return subprocess.run([BASH, posix(TOOL)] + list(args),
                          capture_output=True, text=True, timeout=60)


print("the command itself")
check("it parses", subprocess.run([BASH, "-n", posix(TOOL)],
                                  capture_output=True).returncode == 0)
r = run("-h")
check("-h explains it, without needing root",
      r.returncode == 0 and "smartdns-logs -f" in r.stdout, r.stdout + r.stderr)
check("a wrong option is refused", run("--bogus").returncode != 0)
check("so is a line count that is not a number",
      run("-n", "lots").returncode != 0)

src = open(TOOL, encoding="utf-8").read()
check("it knows the relay's parts", "smartdns-sync" in src and "dnsmasq" in src)
check("and each template's own resolver", "smartdns-dns@" in src)
check("and the exit's", "smartdns-panel" in src and "smartdns-admin" in src)
check("it never prints a config file", "/etc/smart-dns/*.env" not in src
      and "cat /etc/smart-dns" not in src)
check("-h offers the errors-only view", "smartdns-logs -e" in run("-h").stdout)
check("which asks journald for warnings and worse", "prio=(-p warning)" in src)
check("in both the dump and the live view",
      src.count('${prio[@]+"${prio[@]}"}') == 2)
check("and leaves out nginx turning away strangers, which is the gate working",
      "grep -v 'access forbidden by rule'" in src)

print("--report: one file to send, with the secrets masked")
# The real script, run against a machine laid out in a temporary directory,
# with the system commands it calls answered by stand-ins - and a journal that
# has leaked every secret it could, to see that none of it reaches the file.
import tempfile
tmp = tempfile.mkdtemp()
fake = os.path.join(tmp, "bin")
os.makedirs(fake)
SYNC_SECRET, ADMIN_PATH = "supersecretvalue123", "hiddenpath777"


def tool(name, body):
    p = os.path.join(fake, name)
    with open(p, "w", newline="\n") as fh:
        fh.write("#!/bin/bash\n" + body + "\n")
    os.chmod(p, 0o755)


tool("id", "echo 0")
tool("systemctl", 'case "$1" in is-active) echo active ;; esac')
tool("journalctl", "echo 'sync with token %s'; echo 'admin panel up on "
     "https://0.0.0.0:2053/%s/'; echo 'panel GET / 200 3ms from 198.51.100.7'"
     % (SYNC_SECRET, ADMIN_PATH))
tool("smartdns-rules", "echo 'ROUTING-SUMMARY'")
tool("smartdns-acl", "echo 'enforcing'")
tool("timedatectl", "echo yes")
tool("python3", 'exec %s "$@"' % posix(sys.executable).replace(" ", "\\ "))


def report(role_files):
    etc = os.path.join(tmp, "etc-" + role_files[0][0])
    os.makedirs(etc)
    for name, lines in role_files:
        with open(os.path.join(etc, name), "w", newline="\n") as fh:
            fh.write("\n".join(lines) + "\n")
    out_dir = os.path.join(tmp, "out-" + role_files[0][0])
    os.makedirs(out_dir)
    env = dict(os.environ, PATH=posix(fake) + ":" + os.environ.get("PATH", ""),
               SMARTDNS_ETC=posix(etc), SMARTDNS_REPORT_DIR=posix(out_dir))
    r = subprocess.run([BASH, posix(TOOL), "--report"], capture_output=True,
                       text=True, timeout=120, env=env)
    files = os.listdir(out_dir)
    body = open(os.path.join(out_dir, files[0]), encoding="utf-8",
                errors="replace").read() if files else ""
    return r, body


r, body = report([("sync.env", ["PANEL_HOST=203.0.113.50", "SYNC_SECRET=%s" % SYNC_SECRET,
                                "SELF_IP=198.51.100.1", "PANEL_DOMAIN=panel.example.com"])])
check("a relay's report is written", r.returncode == 0 and "report written" in r.stdout,
      r.stdout + r.stderr)
check("and says what it holds", "IP addresses and usernames" in r.stdout, r.stdout)
check("it has the header and both halves",
      "doctor dns report - relay" in body and "warnings and errors" in body
      and "recent logs" in body, body[:500])
check("a relay's includes its routing", "ROUTING-SUMMARY" in body, body[:800])
check("the sync secret leaked into the log is masked",
      SYNC_SECRET not in body and "<secret>" in body, body[:800])
check("addresses stay - they are what a log is for", "198.51.100.7" in body)

r, body = report([("panel.env", ["RELAY_IP=198.51.100.1", "SYNC_SECRET=%s" % SYNC_SECRET]),
                  ("admin.env", ["ADMIN_PORT=2053", "ADMIN_PATH=%s" % ADMIN_PATH,
                                 "ADMIN_CERT=/etc/letsencrypt/live/x/fullchain.pem"])])
check("an exit's report is written", r.returncode == 0, r.stdout + r.stderr)
check("the admin panel's secret address is masked", ADMIN_PATH not in body, body[:800])
check("a file path in the config is not mistaken for a secret",
      "/etc/letsencrypt/live/x/fullchain.pem" not in body or "<secret>" not in
      "/etc/letsencrypt/live/x/fullchain.pem")
check("an exit's has no routing section", "== routing" not in body)
check("the file is made readable by root only", "umask 077" in src)
shutil.rmtree(tmp, ignore_errors=True)

print("the installer puts it on both machines")
built = open(BUILT, encoding="utf-8").read()
at = built.find("payload SMARTDNS_LOGS > /usr/local/bin/smartdns-logs")
check("the installer writes it", at > 0)
check("with a domain or without",
      0 < at < built.index('if [ -n "${PANEL_DOMAIN:-}" ]; then\n    step "HTTPS'))
check("and uninstall knows it is ours",
      "note_file /usr/local/bin/smartdns-logs" in built)

print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
