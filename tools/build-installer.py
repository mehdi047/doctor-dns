"""Assemble doctor-dns.sh from the templates in this repo.

The installer has to be one self-contained file: someone who clones nothing and
downloads only doctor-dns.sh should get a working relay or exit. So every config
lives inside it, below `exit 0`, between markers that awk copies out.

Each payload line is prefixed with '#'. That is what keeps the whole file valid
bash, so `bash -n doctor-dns.sh` genuinely checks it - without the prefix, nginx
braces and dnsmasq syntax make the parser choke even though the data sits after
exit 0 and would never run. The alternative, base64, would pass the check too but
leave a reviewer unable to read the configs they are about to run as root.

This script is the single source of truth in the other direction: edit the files
under templates/ and common/, then re-run this to regenerate doctor-dns.sh.
"""
import io
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(rel):
    with io.open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
        return fh.read().rstrip("\n")


PAYLOADS = [
    ("SYSCTL", "common/sysctl-tuning.conf"),
    ("SYSCTL_BBR", "common/sysctl-bbr.conf"),
    ("BYPASS", "common/bypass.conf"),
    ("NO_AAAA", "common/no-aaaa.conf"),
    ("EXIT_NGINX", "templates/exit-nginx.conf"),
    ("RELAY_NGINX", "templates/relay-nginx.conf"),
    ("TURNSERVER", "templates/turnserver.conf"),
    ("SMARTDNS", "templates/smartdns"),
    ("NFTABLES", "templates/nftables-smartdns.conf"),
    ("SMARTDNS_ACL", "templates/smartdns-acl"),
    ("SMARTDNS_SHAPE", "templates/smartdns-shape"),
    ("ACL_SAVE_SERVICE", "templates/smartdns-acl-save.service"),
    ("ACL_SAVE_TIMER", "templates/smartdns-acl-save.timer"),
    ("PANEL", "templates/smartdns-panel"),
    ("PANEL_SERVICE", "templates/smartdns-panel.service"),
    ("SYNC", "templates/smartdns-sync"),
    ("SYNC_SERVICE", "templates/smartdns-sync.service"),
    ("DNS_PROFILE_UNIT", "templates/smartdns-dns@.service"),
    ("CERT", "templates/smartdns-cert"),
    ("CERT_SERVICE", "templates/smartdns-cert.service"),
    ("CERT_TIMER", "templates/smartdns-cert.timer"),
    ("ADMIN", "templates/smartdns-admin"),
    ("ADMIN_SERVICE", "templates/smartdns-admin.service"),
    ("SMARTDNS_ACCESS", "templates/smartdns-access"),
    ("SMARTDNS_LOGS", "templates/smartdns-logs"),
    ("EPIC_PIN", "templates/epic-pin"),
    ("EPIC_PIN_SERVICE", "templates/epic-pin.service"),
    ("EPIC_PIN_TIMER", "templates/epic-pin.timer"),
    ("DOMAINS", "domains/domains.txt"),
    ("SERVICES", "domains/services.json"),
]


def main():
    logic = read("tools/installer-logic.sh")
    parts = [logic, "", "# " + "=" * 68,
             "# Config payloads. Everything below is data, never executed.",
             "# " + "=" * 68, ""]
    for name, path in PAYLOADS:
        body = read(path)
        # relay-nginx.conf carries MODULE_PATH; the installer fills it in after
        # writing, so normalise it to the same placeholder style as the rest.
        if name == "RELAY_NGINX":
            body = body.replace("load_module MODULE_PATH;",
                                "load_module __MODULE_PATH__;")
        if "#__BEGIN_" in body or "#__END_" in body:
            raise SystemExit("%s contains a payload marker" % path)
        parts.append("#__BEGIN_%s__" % name)
        commented = [("#" + line) for line in body.split("\n")]
        parts.append("\n".join(commented))
        parts.append("#__END_%s__" % name)
        parts.append("")

    text = "\n".join(parts)
    dest = os.path.join(ROOT, "doctor-dns.sh")
    with io.open(dest, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    os.chmod(dest, 0o755)
    print("wrote doctor-dns.sh: %d lines, %d KB, %d payloads"
          % (text.count("\n") + 1, len(text) // 1024, len(PAYLOADS)))


if __name__ == "__main__":
    main()
