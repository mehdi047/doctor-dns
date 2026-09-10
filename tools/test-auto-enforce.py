#!/usr/bin/env python3
"""A relay is closed from the moment it is installed.

It used to be open until the first customer registered, on the reasoning that
enforcing against an empty allowlist cuts everyone off. On a fresh relay there
is nobody to cut off, and what waiting really meant was a relay anybody who
learnt its address could use for free until somebody noticed. So the installer
closes it, and `smartdns-acl` takes --allow-empty to let it.

The refusal it bypasses is still there for a person at a terminal: switching
this on by hand with nobody registered is almost always a mistake, and one
that feels irreversible from the far end of a broken connection.

The note the installer used to leave is still honoured by the sync agent, for
relays installed before this - so that half is tested too: it never fires on
an empty list, fires exactly once, does not fire on a relay deliberately
opened, and a failure to close leaves the note rather than losing the intent.
"""
import importlib.machinery
import importlib.util
import os
import shutil
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


spec = importlib.util.spec_from_loader(
    "sync", importlib.machinery.SourceFileLoader(
        "sync", os.path.join(HERE, "..", "templates", "smartdns-sync")))
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)

tmp = tempfile.mkdtemp()
note = os.path.join(tmp, "auto-enforce")
sync.AUTO_ENFORCE = note

calls = []


class Result:
    def __init__(self, rc=0, out=""):
        self.returncode, self.stdout, self.stderr = rc, out, ""


def fake(status="open", enforce_rc=0):
    def run(args, **kw):
        calls.append(args)
        if args[-1] == "status":
            return Result(0, status)
        return Result(enforce_rc)
    return run


def arm():
    open(note, "w").close()


print("an empty allowlist is never enforced against")
arm()
calls.clear()
sync.subprocess = type("S", (), {"run": staticmethod(fake())})()
sync.close_relay_when_ready(0)
check("nothing was run", not calls, str(calls))
check("the note is kept for later", os.path.exists(note))

print("with no note, nothing happens even when addresses exist")
os.unlink(note)
calls.clear()
sync.close_relay_when_ready(5)
check("nothing was run", not calls, str(calls))

print("the first sync that brings an address closes the relay")
arm()
calls.clear()
sync.subprocess = type("S", (), {"run": staticmethod(fake())})()
sync.close_relay_when_ready(3)
check("it asked the current state first",
      calls and calls[0][-1] == "status", str(calls))
check("it switched enforcement on without prompting",
      any(a[-3:] == ["enforce", "on", "--yes"] for a in calls), str(calls))
check("the note is consumed", not os.path.exists(note))

print("it does not fire twice")
calls.clear()
sync.close_relay_when_ready(3)
check("nothing was run the second time", not calls, str(calls))

print("a relay already enforcing just drops the note")
arm()
calls.clear()
sync.subprocess = type("S", (), {"run": staticmethod(fake(status="enforcing"))})()
sync.close_relay_when_ready(3)
check("it did not try to switch on again",
      not any("on" in a for a in calls), str(calls))
check("the note is dropped", not os.path.exists(note))

print("a failed attempt keeps the note for the next sync")
arm()
calls.clear()
sync.subprocess = type("S", (), {"run": staticmethod(fake(enforce_rc=1))})()
sync.close_relay_when_ready(3)
check("it tried", any("on" in a for a in calls), str(calls))
check("the note survives so the next sync retries", os.path.exists(note))

print("the acl tool cancels the note when opened by hand")
acl = open(os.path.join(HERE, "..", "templates", "smartdns-acl"),
           encoding="utf-8").read()
check("AUTO is defined", "\nAUTO=/etc/smart-dns/auto-enforce" in acl)
off = acl[acl.index("    off)"):acl.index("    status)")]
check("enforce off removes it", 'rm -f "$AUTO"' in off, off[:200])
check("and says so", "cancelled" in off)

print("the installer closes the relay rather than leaving a note")
logic = open(os.path.join(HERE, "installer-logic.sh"), encoding="utf-8").read()
check("it switches enforcement on",
      "smartdns-acl enforce on --yes --allow-empty" in logic)
check("it no longer leaves a note to do it later",
      "> /etc/smart-dns/auto-enforce" not in logic)
check("and clears any note an older install left",
      "rm -f /etc/smart-dns/auto-enforce" in logic)
check("ENFORCE=no still opts out", 'ENFORCE:-yes}" = no' in logic)
check("a relay left open says so loudly",
      "this relay is open to everyone until you close it" in logic)
check("and a failure to close is not silent",
      "could not switch access control on" in logic)
check("the summary says only registered addresses get through",
      "Access control is on" in logic)

print("the refusal still stands for a person typing it")
on = acl[acl.index("    on)"):acl.index("    off)")]
check("an empty allowlist is refused by default",
      "the allowlist is empty - everyone would be cut off" in on)
check("unless --allow-empty is given", "--allow-empty" in on)
check("--yes still skips the confirmation, on its own", "--yes) yes=yes" in on)
check("the two flags are separate",
      "--allow-empty) empty=yes" in on and '"$empty" != yes' in on)
check("and closing an empty relay says what it means",
      "nobody may use this relay yet" in on)

shutil.rmtree(tmp, ignore_errors=True)
print()
if fails:
    print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("all checks passed")
