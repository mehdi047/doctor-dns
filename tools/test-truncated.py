#!/usr/bin/env python3
"""A half-downloaded installer has to refuse to run.

This is the failure that actually happens - not an attack, a connection that
dropped. And it is nastier than it looks, because everything doctor-dns.sh
writes lives below `exit 0` with every line commented out. Cut the file
anywhere in that tail and what is left still parses as bash, still passes
`bash -n`, and still runs. It would install a machine with configs silently
missing, which is worse than not installing at all.

So the script checks its own last lines before it does anything, and the
checks here drive the real script with everything that touches the machine
stubbed out.
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
INSTALLER = os.path.join(HERE, "..", "doctor-dns.sh")
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


tmp = tempfile.mkdtemp()
binn = os.path.join(tmp, "bin")
os.makedirs(binn)

# Nothing below the preflight may reach the machine. Past its checks the
# installer asks which side this machine is, and with no terminal that read
# gets end-of-file and it stops - so that question is the marker for "the
# preflight passed", and apt-get failing is the backstop behind it.
for name, body in [("id", "#!/bin/sh\necho ${FAKE_UID:-0}\n"),
                   ("apt-get", "#!/bin/sh\necho APT-REACHED >&2\nexit 1\n"),
                   ("systemctl", "#!/bin/sh\nexit 0\n")]:
    p = os.path.join(binn, name)
    open(p, "w", newline="\n").write(body)
    os.chmod(p, 0o755)

whole = open(INSTALLER, "rb").read()


def run(data, *args, **env):
    script = os.path.join(tmp, "doctor-dns.sh")
    open(script, "wb").write(data)
    e = dict(os.environ, PATH=binn + os.pathsep + os.environ["PATH"])
    e.update(env)
    return subprocess.run([BASH, posix(script)] + list(args), env=e,
                          capture_output=True, text=True, timeout=180,
                          stdin=subprocess.DEVNULL)


print("the whole file gets past the preflight")
r = run(whole)
out = r.stdout + r.stderr
check("it did not call itself incomplete", "incomplete" not in out, out[-200:])
check("and it got as far as asking which side this machine is",
      "Which side is this machine" in out, out[-300:])

print("a file cut off inside the payloads refuses to run")
# Still valid bash and still 300 KB: neither `bash -n` nor a size check would
# catch this one. Only the tail does.
cut = whole[:len(whole) - 40000]
check("the cut file is still valid bash",
      subprocess.run([BASH, "-n", "-"], input=cut,
                     capture_output=True).returncode == 0)
r = run(cut)
out = r.stdout + r.stderr
check("it says it is incomplete", "incomplete" in out, out[-300:])
check("it stopped before asking anything",
      "Which side is this machine" not in out and "APT-REACHED" not in out,
      out[-300:])
check("it exited non-zero", r.returncode != 0, str(r.returncode))
check("and it says how to get a whole one",
      "raw.githubusercontent.com" in out, out[-300:])

print("so does one cut in the middle of the script")
r = run(whole[:120000])
out = r.stdout + r.stderr
check("it refuses", r.returncode != 0, str(r.returncode))
check("and stopped before asking anything",
      "Which side is this machine" not in out and "APT-REACHED" not in out,
      out[-300:])

print("the last payload terminator is what it looks for")
check("the built file ends on one",
      whole.rstrip(b"\n").split(b"\n")[-1].startswith(b"#__END_"),
      whole.rstrip(b"\n").split(b"\n")[-1][:40].decode("utf-8", "replace"))

print("it still refuses to run for anyone but root")
r = run(whole, FAKE_UID="1000")
out = r.stdout + r.stderr
check("it says to use sudo", "run as root" in out, out[-200:])
check("and stopped before asking anything",
      "Which side is this machine" not in out and "APT-REACHED" not in out,
      out[-200:])

print("nothing tells people to pipe it into bash")
src = open(os.path.join(HERE, "installer-logic.sh"), encoding="utf-8").read()
check("the script says why piping cannot work",
      "Piping it into bash will not work" in src)
pair = [os.path.join(HERE, "..", n) for n in ("README.md", "README.fa.md")]
if not all(os.path.exists(p) for p in pair):
    print("  --   not the published tree - skipped")
else:
    for p in pair:
        txt = open(p, encoding="utf-8").read()
        name = os.path.basename(p)
        check("%s names doctor-dns.sh" % name,
              "raw.githubusercontent.com/mehdi047/doctor-dns/main/"
              "doctor-dns.sh" in txt)
        check("%s does not pipe curl into a shell" % name,
              "| sudo sh" not in txt and "| sudo bash" not in txt)
        check("%s has no get.sh left" % name, "get.sh" not in txt)

shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
