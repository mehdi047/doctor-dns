#!/usr/bin/env python3
"""Which ports the operator may not pick, and being told before they pick.

The admin panel is the one port in this service the operator chooses, and the
choice is easy to get wrong because most of what is already listening belongs
to the service itself. Getting it wrong is not a small thing either: taking
443 means the proxy cannot start, and taking 8443 means every relay quietly
stops syncing.

Being told afterwards is not much help - by then the port is usually already
in a firewall rule somewhere. So the warning comes before the question, and
these checks hold the warning, the refusal, and the documentation to the same
list.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
LOGIC = os.path.join(HERE, "installer-logic.sh")
BUILT = os.path.join(HERE, "..", "doctor-dns.sh")
ACCESS = os.path.join(HERE, "..", "templates", "smartdns-access")
fails = []

TAKEN = ["22", "53", "80", "443", "8443"]
FREE = ["9443", "2053", "31337"]


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

print("the warning comes before the question")
warn_at = src.find('warn "these ports are taken')
ask_at = src.find('read -r -p "  port to serve it on')
check("both are in the built script", warn_at > 0 and ask_at > 0,
      "%d %d" % (warn_at, ask_at))
check("and the warning is first", 0 < warn_at < ask_at)
check("it is a warning, so it is yellow",
      'warn() { printf \'    %s%s%s\\n\' "$Y"' in src)

print("it names every port that is taken")
block = src[warn_at:ask_at]
for p in TAKEN:
    check("it names %s" % p, re.search(r"\b%s\b" % p, block) is not None,
          block[:200])
check("and says the relay takes 3478 too", "3478" in block)
check("and does not name a port that no longer exists",
      "8080" not in block, block)
check("and says to open the chosen one in the firewall",
      "firewall" in block)

print("and the script refuses those ports if one is typed anyway")
# The real case block, lifted out and given the die() it calls.
m = re.search(r'case "\$ADMIN_PORT" in\n(.*?)\n\s*esac', src, re.S)
check("the validation block was found", m is not None)
tmp = tempfile.mkdtemp()
if m:
    harness = os.path.join(tmp, "ports.sh")
    open(harness, "w", newline="\n", encoding="utf-8").write(
        'die() { printf "ERROR: %s\\n" "$*" >&2; exit 1; }\n'
        'ADMIN_PORT="$1"\n'
        'case "$ADMIN_PORT" in\n' + m.group(1) + '\nesac\n'
        'echo ACCEPTED\n')

    def try_port(p):
        return subprocess.run([BASH, posix(harness), p], capture_output=True,
                              text=True, timeout=60)

    for p in TAKEN:
        r = try_port(p)
        check("%s is refused" % p, r.returncode != 0 and "ACCEPTED" not in r.stdout,
              r.stdout + r.stderr)
        check("  and it says why", len(r.stderr.strip()) > 15, r.stderr)
    for p in FREE:
        r = try_port(p)
        check("%s is allowed" % p, "ACCEPTED" in r.stdout, r.stdout + r.stderr)
    for bad in ("", "https", "80a"):
        r = try_port(bad)
        check("%r is refused as not a number" % bad, r.returncode != 0,
              r.stdout + r.stderr)

print("the command the summary tells you to run is actually installed")
# It used to be written only inside the "we have a domain" branch, while the
# end-of-run message told a machine with no domain to run it. The one reader
# who needed it was the one who could not have it.
cert_at = src.index("payload CERT > /usr/local/bin/smartdns-cert")
domain_gate = src.index('if [ -n "${PANEL_DOMAIN:-}" ]; then\n    step "HTTPS')
check("smartdns-cert is installed before the domain check", cert_at < domain_gate)
check("and only written once", src.count("payload CERT >") == 1,
      str(src.count("payload CERT >")))
check("the summary points at it", "smartdns-cert panel.example.com" in src)
helper = open(os.path.join(HERE, "..", "templates", "smartdns-cert"),
              encoding="utf-8").read()
check("and it installs certbot itself when it is missing",
      "command -v certbot" in helper and "apt-get install" in helper)

print("smartdns-access refuses the same list")
acc = open(ACCESS, encoding="utf-8").read()
for p in TAKEN:
    check("it knows about %s" % p, re.search(r"\b%s\b" % p, acc) is not None)

print("the README says which they are")
pair = [os.path.join(HERE, "..", n) for n in ("README.md", "README.fa.md")]
if not all(os.path.exists(p) for p in pair):
    print("  --   not the published tree - skipped")
else:
    for p in pair:
        txt = open(p, encoding="utf-8").read()
        name = os.path.basename(p)
        missing = [x for x in TAKEN + ["3478"]
                   if not re.search(r"\b%s\b" % x, txt)]
        check("%s lists every port in use" % name, not missing, str(missing))
        # The plain-http panel is gone. A README that still lists its port
        # tells an operator to open a hole in the firewall for nothing.
        check("%s does not still list 8080" % name, "8080" not in txt)
        check("%s says the panel port must not be one of them" % name,
              "9443" in txt)

shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
