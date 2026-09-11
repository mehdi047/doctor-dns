#!/usr/bin/env python3
"""Google's own names leave the exit over IPv6, where the exit has it.

Google refused Gemini, AI Studio, NotebookLM and Labs to a live exit's IPv4
address - 403 - and served the same machine the real pages over IPv6. The
exit's nginx only ever connected out over IPv4, so a customer could reach
everything but Gemini. The fix sends Google's names through a loopback hop
whose resolver asks for AAAA records only; everything else is unchanged.

What has to hold: the block is there when the exit can use it, gone when it
cannot - and gone means the file behaves exactly as it did before, blackholes
included - and the installer decides which on a real IPv6 connection to
Google and an nginx new enough to have `ipv4=off`.
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
fails = []


def check(label, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + label +
          ((" - " + str(detail)[:500]) if detail and not cond else ""))
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


conf = open(os.path.join(HERE, "..", "templates", "exit-nginx.conf"), encoding="utf-8").read()
logic = open(os.path.join(HERE, "installer-logic.sh"), encoding="utf-8").read()
stream = conf[conf.index("stream {"):]

print("the exit's config")
check("the public server passes to $upstream", "proxy_pass $upstream;" in stream)
check("$upstream is chosen from $target, so the blackholes still apply first",
      "map $target $upstream {" in stream and "map $ssl_preread_server_name $target {" in stream)
check("everything else leaves as before, $target:443", "default  $target:443;" in stream)
check("Google's names go to the loopback hop",
      re.search(r"google\\.com\|googleapis\\.com.*\$\s+127\.0\.0\.1:8446;", stream) is not None)
check("the hop is on loopback only", "listen 127.0.0.1:8446;" in stream
      and not re.search(r"listen\s+8446", stream))
check("and asks its resolver for AAAA records only", "resolver 1.1.1.1 ipv4=off;" in stream)
check("the public server still resolves over IPv4 only",
      stream.index("resolver 1.1.1.1 ipv6=off;") < stream.index("listen 443;"))
check("only the relay may use the public server",
      "allow __RELAY_IP__;\n        deny all;" in stream)
check("the block opens and closes in pairs",
      stream.count("# google-v6 begin") == 2 and stream.count("# google-v6 end") == 2)


def strip(text, off):
    """What install_payload's sed does to the file, run through bash's sed."""
    env = dict(os.environ)
    if off:
        env["NO_GOOGLE_V6"] = "1"
    else:
        env.pop("NO_GOOGLE_V6", None)
    r = subprocess.run([BASH, "-c", 'sed -e "${NO_GOOGLE_V6:+/# google-v6 begin/,/# google-v6 end/d}"'],
                       input=text.encode(), capture_output=True, env=env, timeout=30)
    return r.stdout.decode(), r.returncode


kept, rc1 = strip(conf, off=False)
gone, rc2 = strip(conf, off=True)
print("where the exit has IPv6")
check("the file goes in unchanged", rc1 == 0 and kept == conf)

print("where it does not")
gs = gone[gone.index("stream {"):]
check("sed accepts the expression either way", rc1 == 0 and rc2 == 0)
check("no IPv6 hop is left", "8446" not in gone and "ipv4=off" not in gone, gs)
check("no Google rule is left", r"google\.com" not in gs, gs)
check("what remains sends everything to $target:443 - the old behaviour",
      re.search(r"map \$target \$upstream \{\s*default  \$target:443;\s*\}", gs) is not None, gs)
check("the braces still balance", gone.count("{") == gone.count("}"),
      "%d/%d" % (gone.count("{"), gone.count("}")))
check("and so do they with the block in", conf.count("{") == conf.count("}"))

print("the installer")
check("install_payload drops the block when told to",
      '-e "${NO_GOOGLE_V6:+/# google-v6 begin/,/# google-v6 end/d}"' in logic)
det = logic[logic.index("NO_GOOGLE_V6=1"):logic.index("install_payload EXIT_NGINX")]
check("the default is to leave it out", det.startswith("NO_GOOGLE_V6=1"))
check("only an exit considers it", 'if [ "$ROLE" = exit ]; then' in det)
check("it needs a real IPv6 connection to Google",
      "curl -6 -s -o /dev/null -m 10 https://www.google.com/" in det)
check("and an nginx with ipv4=off, 1.23.1 or later", "1.23.1" in det and "sort -V" in det)
check("and says which way it went", det.count("info ") == 2)

print("the version test, run")
version_line = [l for l in det.splitlines() if "sort -V" in l][0].strip()
test = version_line.replace("if ", "", 1).rstrip("\\").rstrip()
for ngv, want in (("1.22.1", False), ("1.23.0", False), ("1.23.1", True),
                  ("1.24.0", True), ("1.27.4", True), ("", False)):
    r = subprocess.run([BASH, "-c", 'ngv="%s"; %s' % (ngv, test)], capture_output=True, timeout=30)
    check("nginx %s -> %s" % (ngv or "(none)", "on" if want else "off"),
          (r.returncode == 0) == want, r.stderr.decode())

print("port 8446 belongs to the service")
for name in ("smartdns-access", "smartdns-admin"):
    src = open(os.path.join(HERE, "..", "templates", name), encoding="utf-8").read()
    check("%s refuses it for the admin panel" % name, "8446" in src)
check("so does the installer", '8446) die "port 8446' in logic)

print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
