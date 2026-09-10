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
