#!/usr/bin/env python3
"""get.sh: the one-line install, and what it refuses to hand to bash.

Piping a downloader into a shell is only as safe as what it checks before it
hands over, and the failure that actually happens is not an attack - it is a
download that stopped early. doctor-dns.sh carries every config it writes in
its own tail, all of it commented out, so a file cut in half still parses as
bash and still runs. It would set up a machine with pieces silently missing.

So the checks here are about completeness, and the other thing worth testing
is the terminal: the installer asks which side of the service this machine
is, and piped into sh those prompts would read the pipe and get end-of-file.
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
GET = os.path.join(HERE, "..", "get.sh")
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
served = os.path.join(tmp, "served")     # what the fake curl hands back
asked = os.path.join(tmp, "asked")       # the URL it was asked for


def stub(name, body):
    p = os.path.join(binn, name)
    open(p, "w", newline="\n").write(body)
    os.chmod(p, 0o755)


stub("id", "#!/bin/sh\necho ${FAKE_UID:-0}\n")
# curl -fsSL URL -o FILE. Records the URL, then serves whatever the test put
# in place - or fails, when the test wants a failed download.
stub("curl", "#!/bin/sh\n"
             "for a in \"$@\"; do case \"$a\" in http*) echo \"$a\" > '%s';;"
             " esac; done\n"
             "[ -z \"${FAKE_CURL_FAIL:-}\" ] || exit 22\n"
             "shift $(($# - 1))\n"
             "cp '%s' \"$1\"\n" % (posix(asked), posix(served)))
# The real bash for the syntax check - that one is the point - and a stub for
# the hand-off, so a test run never actually installs anything.
stub("bash", "#!/bin/sh\n"
             "if [ \"$1\" = -n ]; then exec '%s' \"$@\"; fi\n"
             "echo \"HANDOFF $*\"\n" % posix(BASH))
stub("wget", "#!/bin/sh\nexit 1\n")

DEST = os.path.join(tmp, "dest")


def run(*args, **env):
    if os.path.exists(DEST):
        shutil.rmtree(DEST)
    if os.path.exists(asked):
        os.remove(asked)
    e = dict(os.environ, PATH=binn + os.pathsep + os.environ["PATH"],
             DEST=posix(DEST))
    e.update({k: str(v) for k, v in env.items()})
    return subprocess.run([BASH, posix(GET)] + list(args), capture_output=True,
                          text=True, env=e, timeout=180, stdin=subprocess.DEVNULL)


def landed():
    return os.path.exists(os.path.join(DEST, "doctor-dns.sh"))


whole = open(INSTALLER, "rb").read()
open(served, "wb").write(whole)

print("it parses as the POSIX shell it claims to be")
check("sh -n get.sh",
      subprocess.run(["sh", "-n", posix(GET)], capture_output=True).returncode == 0)

print("the whole installer goes through")
r = run()
check("it saved the installer", landed())
check("what it saved is byte-for-byte what it fetched",
      landed() and
      open(os.path.join(DEST, "doctor-dns.sh"), "rb").read() == whole)
check("it printed a checksum to compare", "sha256" in r.stdout)
check("it fetched from the repo, on main",
      open(asked).read().strip() ==
      "https://raw.githubusercontent.com/mehdi047/doctor-dns/main/doctor-dns.sh",
      open(asked).read())

print("with no terminal it stops rather than answering the prompts itself")
# The run above: stdin is /dev/null and there is no controlling terminal.
# The installer asks which side of the service this machine is and what the
# other one's address is, and there is nobody here to ask.
check("it did not run the installer", "HANDOFF" not in r.stdout, r.stdout[-200:])
check("it said why", "no terminal" in r.stdout, r.stdout[-200:])
check("and gave the command to run instead",
      "sudo bash" in r.stdout and "doctor-dns.sh" in r.stdout, r.stdout[-200:])
check("it exited non-zero", r.returncode != 0, str(r.returncode))

print("arguments are carried through")
r = run("--uninstall")
check("--uninstall comes back in the command it prints",
      "doctor-dns.sh --uninstall" in r.stdout, r.stdout[-200:])

print("given a terminal, it hands over")
if os.name == "nt":
    print("  --   no pty on this platform - skipped")
else:
    import pty
    if os.path.exists(DEST):
        shutil.rmtree(DEST)
    master, slave = pty.openpty()
    try:
        env = dict(os.environ, PATH=binn + os.pathsep + os.environ["PATH"],
                   DEST=posix(DEST))
        p = subprocess.run([BASH, posix(GET), "--uninstall"], stdin=slave,
                           capture_output=True, text=True, env=env, timeout=180)
    finally:
        os.close(master)
        os.close(slave)
    check("it ran the installer", "HANDOFF" in p.stdout, p.stdout[-200:])
    check("and passed the argument on", "--uninstall" in p.stdout,
          p.stdout[-200:])

print("REF installs from somewhere other than main")
r = run(REF="v0.2")
check("the tag is in the URL", "/v0.2/doctor-dns.sh" in open(asked).read(),
      open(asked).read())

print("a download that stopped early is refused")
open(served, "wb").write(whole[:150000])
r = run()
check("it says how little arrived", "150000 bytes" in (r.stderr + r.stdout),
      r.stderr[-200:])
check("and nothing was installed", not landed())

print("and so is one that stopped inside the payloads")
# Big enough to pass the size check and still valid bash, because everything
# below `exit 0` is commented out. This is the cut that would otherwise
# install a machine with configs missing.
open(served, "wb").write(whole[:len(whole) - 40000])
r = run()
check("it notices the payloads are cut",
      "mid-payload" in (r.stderr + r.stdout), r.stderr[-200:])
check("and nothing was installed", not landed())

print("an error page is not an installer")
open(served, "wb").write(b"<!DOCTYPE html>\n<html><body>404</body></html>\n" * 6000)
r = run()
check("it refuses HTML", "not the installer" in (r.stderr + r.stdout),
      r.stderr[-200:])
check("and nothing was installed", not landed())

print("a file that does not parse is not run")
broken = whole[:whole.index(b"\nexit 0\n")] + b"\nif then fi (\n" + whole[-40000:]
open(served, "wb").write(broken)
r = run()
check("it refuses it", not landed() and r.returncode != 0, str(r.returncode))
check("and never handed it over", "HANDOFF" not in r.stdout, r.stdout[-200:])

print("a failed download is not treated as a file")
open(served, "wb").write(whole)
r = run(FAKE_CURL_FAIL="1")
check("it says the download failed",
      "could not download" in (r.stderr + r.stdout), r.stderr[-200:])
check("and nothing was installed", not landed())

print("it will not try any of this without root")
r = run(FAKE_UID="1000")
check("it says to use sudo", "run as root" in (r.stderr + r.stdout),
      r.stderr[-200:])
check("and downloaded nothing", not os.path.exists(asked))

print("the published README tells people the command that exists")
# Only the release tree carries the pair. The working repo's README.md is a
# different document - deployment notes that are not published - so there is
# nothing here to check against.
pair = [os.path.join(HERE, "..", n) for n in ("README.md", "README.fa.md")]
if not all(os.path.exists(p) for p in pair):
    print("  --   not the published tree - skipped")
else:
    for p in pair:
        txt = open(p, encoding="utf-8").read()
        name = os.path.basename(p)
        check("%s points at get.sh" % name,
              "raw.githubusercontent.com/mehdi047/doctor-dns/main/get.sh" in txt)
        check("%s has no placeholder host left" % name,
              "example.invalid" not in txt)

shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
