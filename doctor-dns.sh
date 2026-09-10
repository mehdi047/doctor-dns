#!/usr/bin/env bash
#
# Smart DNS installer - sanction-bypass DNS for Iran, in two halves.
#
#   relay  (inside Iran)  dnsmasq answers a list of blocked domains with its own
#                         address; nginx then carries those connections abroad
#   exit   (outside)      nginx reads the SNI and connects to the real host
#
# Run it on both machines, once each. It asks which side it is on and the
# address of the other. Safe to re-run: configs are backed up, and a step that
# would change nothing does nothing.
#
#   sudo bash doctor-dns.sh              install or update this machine
#   sudo bash doctor-dns.sh --uninstall  put the machine back as it was
#
# HTTPS for the panels is optional and asks for nothing but a domain name. A
# certificate is obtained and renewed automatically, proved over port 80 - so
# the name has to point at the machine and port 80 has to be reachable. On a
# relay that port is forwarded to the exit, so it is borrowed for the twenty
# seconds a challenge takes and given straight back; console downloads through
# it stall for that long and resume.
#
# PANEL_CERT and PANEL_KEY use a certificate you already have instead, and
# CF_API_TOKEN proves the domain over DNS without touching port 80. Neither is
# ever prompted for.
#
# Per-client access control ships with this but starts switched off. The relay
# counts each registered address's traffic from the moment it is installed and
# blocks nobody; `smartdns-acl enforce on` is what closes the door, and it is
# meant to be run once there is a way for users to register an address. Turning
# it on before then locks out everyone, including you.

set -euo pipefail

SELF="${BASH_SOURCE[0]}"
STAMP="$(date +%Y%m%d-%H%M%S)"

# What this file is. Written to the machine once an install finishes, so the
# next run can tell whether it is an upgrade, a re-run, or somebody about to
# put an older version over a newer one by accident.
VERSION="0.3.6"

# What this install did, so uninstall can undo exactly that and nothing more.
# Without it, removal would be guesswork: whether dnsmasq was ours or already
# here, whether nginx.conf had a config worth putting back. Guessing wrong on a
# box that was doing something else first is how an uninstall does damage.
STATE_DIR="/var/lib/smart-dns"
STATE="$STATE_DIR/install-state"

# Backups go here, never beside the original. dnsmasq reads *every* file in
# /etc/dnsmasq.d, so a backup left there is loaded as a second copy of the same
# config and the service refuses to start on "illegal repeated keyword". Found
# the hard way: it took a working relay down on the second run.
BACKUP_DIR="/var/backups/smart-dns"

# ---------------------------------------------------------------- output
if [ -t 1 ]; then
    B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; RD=$'\033[31m'; N=$'\033[0m'
else
    B=""; G=""; Y=""; RD=""; N=""
fi
step() { printf '\n%s==>%s %s%s%s\n' "$G" "$N" "$B" "$*" "$N"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    %s%s%s\n' "$Y" "$*" "$N"; }
die()  { printf '\n%sERROR:%s %s\n\n' "$RD" "$N" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- payloads
# Configs live at the bottom of this file, after exit 0, between markers, with
# every line prefixed by '#' so the whole script stays valid bash. awk copies
# them out and strips that prefix - no shell expansion anywhere, so nginx's
# $variables and dnsmasq's syntax survive untouched.
payload() {
    awk -v name="$1" '
        $0 == "#__BEGIN_" name "__" { on = 1; next }
        $0 == "#__END_"   name "__" { on = 0 }
        on { sub(/^#/, ""); print }
    ' "$SELF"
}

backup_file() {
    [ -f "$1" ] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$1" "$BACKUP_DIR/$(basename "$1").$STAMP"
    info "backed up $1 -> $BACKUP_DIR"
}

# Write payload $1 to file $2, substituting the two addresses. Backs up whatever
# was there, and skips the write when the content is identical so re-runs do not
# churn files or trigger needless restarts. Returns 0 only if it changed.
install_payload() {
    local name="$1" dest="$2" tmp
    tmp="$(mktemp)"
    # MODULE_PATH is filled in here, not with a sed -i afterwards, so that what
    # we compare against the installed file is the finished article. Doing it
    # after the comparison meant every run saw a difference and rewrote
    # nginx.conf - the same needless-restart trap epic-pin fell into. MOD is
    # empty for the payloads written before it is discovered, and none of those
    # contain the placeholder.
    payload "$name" \
        | sed -e "s#__RELAY_IP__#${RELAY_IP}#g" \
              -e "s#__EXIT_IP__#${EXIT_IP}#g" \
              -e "s#__MODULE_PATH__#${MOD:-__MODULE_PATH__}#g" \
        > "$tmp"
    [ -s "$tmp" ] || die "payload $name is empty - is this file complete?"
    # Whether this file was ours or already here decides what uninstall does
    # with it: delete, or put the original back. Work it out before writing.
    note_file "$dest"
    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"; info "$dest unchanged"; return 1
    fi
    backup_file "$dest"
    mv "$tmp" "$dest"; chmod 644 "$dest"; info "wrote $dest"
    return 0
}

# Set KEY=VALUE in a shell-style config file, replacing the line if it is
# already there and appending it if not. Used for the panel's config, which the
# operator is expected to edit by hand as well.
set_env_key() {
    local file="$1" key="$2" value="$3" tmp
    tmp="$(mktemp)"
    grep -v "^${key}=" "$file" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# Record a fact about this install, one "key value" per line.
remember() { mkdir -p "$STATE_DIR"; printf '%s %s\n' "$1" "$2" >> "$STATE"; }
recall()   { [ -f "$STATE" ] && awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print }' "$STATE"; }
# The same, on one line. The membership tests below look for a value with a
# space on either side, so a list separated by newlines would only ever match
# its first entry - which is exactly what went wrong: on the second run every
# file this script had created was reclassified as somebody else's.
recall_flat() { recall "$1" | tr '\n' ' '; }

# Enable a service, but only record it as ours if it was not already enabled.
# Uninstall stops what is on that list, and stopping an nginx that was serving
# somebody's website before we arrived would be a real outage caused by our
# cleanup. Restoring its config is ours to undo; its running state is not.
#
# The second argument names the package that provides the unit. Leave it out
# for units this script writes itself, which are ours by construction.
enable_service() {
    local svc="$1" pkg="${2:-}" was ours=no

    # A second run finds our own services already enabled, so the test at the
    # bottom would decide they belong to someone else and uninstall would leave
    # dnsmasq and coturn running for ever. What *this* run enabled is not the
    # question; what any run of this script enabled is.
    case " ${PREV_SERVICES:-} " in *" $svc "*) ours=yes ;; esac

    # Debian enables dnsmasq and coturn the moment they are unpacked, so by the
    # time we get here the "was it already enabled" test says yes even though
    # the package arrived thirty seconds ago on our own apt-get line. If we
    # installed the package, the service is ours.
    if [ -n "$pkg" ]; then
        case " ${NEW_PACKAGES:-} " in *" $pkg "*) ours=yes ;; esac
    else
        ours=yes
    fi

    was="$(systemctl is-enabled "$svc" 2>/dev/null || true)"
    systemctl enable "$svc" >/dev/null 2>&1 || true
    { [ "$ours" = yes ] || [ "$was" != enabled ]; } && remember services-enabled "$svc"
    return 0
}

# Classify a file we are about to write. "replaced" means something was already
# there and uninstall should put it back; "created" means it is ours to delete.
# A re-run must not reclassify: once a file has been recorded as replaced, the
# original still belongs to whoever had it first, even though by now the file on
# disk is ours.
note_file() {
    local f="$1"
    case " $(recall_flat files-created) $(recall_flat files-replaced) " in
        *" $f "*) return 0 ;;
    esac
    case " ${PREV_REPLACED:-} " in
        *" $f "*) remember files-replaced "$f"; return 0 ;;
    esac
    # And a file an earlier run created is still ours to delete. Without this
    # the test below sees a file that exists, concludes it belongs to the
    # machine's owner, and uninstall then tries to restore a backup that was
    # never taken - leaving every config we wrote behind for good.
    case " ${PREV_CREATED:-} " in
        *" $f "*) remember files-created "$f"; return 0 ;;
    esac
    if [ -e "$f" ]; then remember files-replaced "$f"
    else remember files-created "$f"; fi
}

# --------------------------------------------------------------- questions?
# Answered before the preflight, because neither one touches the machine and
# neither has any business demanding root. Asking a script what version it is
# and being told to use sudo is the kind of small rudeness that makes people
# stop asking.
case "${1:-}" in
    --version|-V) printf '%s\n' "$VERSION"; exit 0 ;;
    --help|-h)
        printf 'doctor dns %s\n\n' "$VERSION"
        printf 'usage: sudo bash %s [--uninstall]\n\n' "$0"
        printf '  no arguments   install or update this machine\n'
        printf '  --uninstall    put it back as it was\n'
        printf '  --version      print the version of this file\n'
        printf '\nenvironment (sudo does not pass these, put them after it):\n'
        printf '  ASSUME_YES=1   take the default for every question\n'
        printf '  ENFORCE=no     leave a relay open to everyone\n'
        exit 0 ;;
esac

# ---------------------------------------------------------------- preflight
[ "$(id -u)" = 0 ] || die "run as root:  sudo bash $0"
[ -r "$SELF" ] && [ -n "$(payload SYSCTL)" ] || die "cannot read my own payloads.
    Download this file and run it directly. Piping it into bash will not work,
    because the configs are stored inside the script itself."
# A download that stopped early is still a runnable script. Everything below
# `exit 0` is a comment, so bash parses half a file quite happily and would
# then set the machine up with configs silently missing - which is worse than
# not running at all. A whole one always ends on a payload terminator.
tail -2 "$SELF" | grep -q '^#__END_' || die "this file is incomplete - the
    download stopped early. Fetch it again:
        curl -fsSLO https://raw.githubusercontent.com/mehdi047/doctor-dns/main/doctor-dns.sh"
command -v apt-get >/dev/null 2>&1 || die "this installer expects Debian or Ubuntu"

# ---------------------------------------------------------------- uninstall
# Undoes exactly what the state file says this script did, and nothing else.
# Anything it is unsure about is left alone and reported, because a leftover
# file is a nuisance while a wrongly deleted one is an outage.
uninstall() {
    [ -f "$STATE" ] || die "no record of an install at $STATE.
    Either this machine was never set up by this script, or the state file is
    gone. Refusing to guess what to remove."

    local role packages
    role="$(recall role)"
    packages="$(recall packages-installed)"

    printf '\n%sAbout to remove the smart DNS from this machine.%s\n\n' "$B" "$N"
    printf '    installed as : %s on %s\n' "$role" "$(recall installed-at)"
    printf '    will restore : nginx config, and stop the services set up here\n'
    printf '    will delete  : the config files, helper commands and timers added\n'
    if [ -n "$packages" ]; then
        printf '    will NOT remove these packages, in case something else needs them:\n'
        printf '                   %s\n' "$packages"
    fi
    printf '    backups kept : %s\n\n' "$BACKUP_DIR"
    if [ -z "${ASSUME_YES:-}" ]; then
        read -r -p "  proceed? [y/N]: " ok
        case "$ok" in y|Y|yes) ;; *) die "cancelled" ;; esac
    fi

    step "Stopping services"
    local svc
    for svc in $(recall services-enabled); do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" >/dev/null 2>&1 || true
        info "stopped and disabled $svc"
    done

    step "Removing files this install created"
    local f
    for f in $(recall files-created); do
        if [ -e "$f" ]; then rm -f "$f"; info "removed $f"; fi
    done

    step "Restoring files this install replaced"
    for f in $(recall files-replaced); do
        # The oldest backup is the state the machine was in before we touched
        # it; later ones are just our own edits over time.
        local original
        # `|| true` is load-bearing. Under `set -e` with pipefail, a glob that
        # matches nothing makes ls exit non-zero and takes the whole uninstall
        # down without a word, halfway through - which is precisely how the
        # missing carry-over below first showed itself.
        original="$(ls -1 "$BACKUP_DIR/$(basename "$f")".* 2>/dev/null | head -1 || true)"
        if [ -n "$original" ] && [ -f "$original" ]; then
            cp -a "$original" "$f"; info "restored $f from $(basename "$original")"
        else
            warn "no backup found for $f - left as it is"
        fi
    done

    step "Swap"
    # Only a swap file this script created, and only if it is still the one
    # recorded - never a swap file that was already on the machine.
    if [ -n "$(recall swapfile)" ] && [ -f /swapfile ]; then
        swapoff /swapfile 2>/dev/null || true
        sed -i '\#^/swapfile #d' /etc/fstab 2>/dev/null || true
        rm -f /swapfile
        info "removed the swap file this installer created"
    fi

    step "Removing the firewall table"
    export PATH="$PATH:/usr/sbin"
    if nft list table inet smartdns >/dev/null 2>&1; then
        nft delete table inet smartdns; info "removed the nftables table"
    fi
    # 10- is recorded in the state file and goes with the other created files.
    # 20- and 30- are not: smartdns-acl writes them at runtime, long after the
    # install, so nothing recorded them. The allowlist in 20- is worth keeping,
    # so it moves to the backups rather than being deleted - reinstalling and
    # discovering every customer's registered address is gone would be a poor
    # way to learn that uninstall is destructive.
    if [ -f /etc/nftables.d/20-smartdns-state.conf ]; then
        backup_file /etc/nftables.d/20-smartdns-state.conf
        rm -f /etc/nftables.d/20-smartdns-state.conf
        info "allowlist kept in $BACKUP_DIR"
    fi
    rm -f /etc/nftables.d/30-smartdns-enforce.conf
    rm -f /etc/nftables.d/smartdns.conf

    step "Panel"
    # /etc/smart-dns holds the bot token, the shared secret and the sync
    # certificate. Deleting them outright would mean re-pairing every relay
    # after an uninstall that was only meant to move things around, so they go
    # to the backups instead.
    if [ -d /etc/smart-dns ]; then
        mkdir -p "$BACKUP_DIR"
        cp -a /etc/smart-dns "$BACKUP_DIR/smart-dns-config.$STAMP"
        rm -rf /etc/smart-dns
        info "credentials moved to $BACKUP_DIR/smart-dns-config.$STAMP"
    fi
    # The database is the customers, their balances and their usage. It is
    # never deleted by an uninstall, and it is not moved either, so that
    # reinstalling on the same machine simply picks it up again.
    if [ -f "$STATE_DIR/panel.db" ]; then
        info "database left where it is: $STATE_DIR/panel.db"
    fi

    step "Restarting what is left"
    systemctl daemon-reload
    # nginx is only left running if it was already enabled before we arrived,
    # i.e. it is not on the list we just disabled. In that case it now has its
    # original config back and should be put back into service.
    case " $(recall_flat services-enabled) " in
        *" nginx "*) info "nginx was installed here by this script - left stopped" ;;
        *)
            if nginx -t >/dev/null 2>&1; then
                systemctl restart nginx; info "nginx restarted with its original config"
            else
                warn "the restored nginx config does not parse - nginx left alone"
            fi ;;
    esac

    rm -f "$STATE"
    # The version note goes with the state it describes. Left behind, it would
    # tell a later install that this machine already runs a version whose
    # files are no longer here, and that install would skip its own upgrade
    # question on the strength of it.
    rm -f "$STATE_DIR/version"
    # Only if nothing else put anything there; never blow away a
    # directory a later stage of this project may be using.
    rmdir "$STATE_DIR" 2>/dev/null || true
    printf '\n%sRemoved.%s Backups are still in %s if you want anything back.\n\n' "$G" "$N" "$BACKUP_DIR"
    if [ -n "$packages" ]; then
        printf '    To also remove the packages it installed:\n\n'
        printf '        apt-get purge %s\n\n' "$packages"
    fi
    exit 0
}

# --version and --help were answered above, before the preflight.
case "${1:-}" in
    --uninstall|-u|uninstall) uninstall ;;
    "") ;;
    *) die "unknown argument: $1  (try --help)" ;;
esac

# ---------------------------------------------------------------- version
# Nothing below has touched the machine yet, and the answer here decides
# whether anything will. Two cases are worth stopping for: an upgrade, which
# the operator should know is happening rather than discover afterwards, and
# the reverse - an older file run over a newer install, which is nearly always
# somebody re-running a download they still had lying around.
VERSION_FILE="$STATE_DIR/version"
INSTALLED_VERSION=""
[ -f "$VERSION_FILE" ] && INSTALLED_VERSION="$(head -1 "$VERSION_FILE" | tr -d "[:space:]")" || true

# The customer database, the settings, the sync secret and any certificate all
# live outside the files this script writes, and every payload it does write is
# backed up before it is replaced. So an upgrade keeps them - but "keeps them"
# is a promise worth a copy behind it, taken before anything starts.
snapshot_db() {
    local db="$STATE_DIR/panel.db" out
    [ -f "$db" ] || return 0
    mkdir -p "$BACKUP_DIR"
    out="$BACKUP_DIR/panel.db.$STAMP"
    # VACUUM INTO, not cp: the panel keeps a write-ahead log beside the file,
    # so a plain copy of the file alone can be a database missing its newest
    # rows. Falls back to cp where sqlite is too old to know the statement.
    if python3 - "$db" "$out" <<'PY' 2>/dev/null
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("VACUUM INTO ?", (sys.argv[2],))
db.close()
PY
    then
        info "database copied to $out"
    elif cp -a "$db" "$out" 2>/dev/null; then
        warn "database copied to $out (plain copy - sqlite here is old)"
    else
        die "could not copy the database at $db. Fix that before upgrading."
    fi
}

if [ -n "$INSTALLED_VERSION" ] && [ "$INSTALLED_VERSION" != "$VERSION" ]; then
    older="$(printf '%s\n%s\n' "$INSTALLED_VERSION" "$VERSION" | sort -V | head -1)"
    printf '\n%sVersion%s\n\n' "$B" "$N"
    info "installed on this machine:  $INSTALLED_VERSION"
    info "this file:                  $VERSION"
    printf '\n'
    if [ "$older" = "$VERSION" ]; then
        warn "this file is OLDER than what is installed."
        warn "installing it will put old configs over new ones, and this"
        warn "script has no way to undo what a later version did."
        warn "the newest is at github.com/mehdi047/doctor-dns/releases"
        answer=n
    else
        warn "this will upgrade this machine from $INSTALLED_VERSION to $VERSION."
        answer=y
    fi
    warn "your customers, settings, certificates and allowlist are kept."
    printf '\n'
    if [ -z "${ASSUME_YES:-}" ]; then
        read -r -p "  go ahead? [$answer]: " reply
        # An answer piped in from a file written on Windows arrives with
        # a carriage return attached, and a "y" with one glued on
        # matches nothing below.
        reply="$(printf '%s' "$reply" | tr -d '\r')"
        reply="${reply:-$answer}"
    else
        reply="$answer"
        info "ASSUME_YES - taking '$answer'"
    fi
    case "$reply" in
        y|Y|yes|YES) ;;
        *) printf '\n    Nothing was changed.\n\n'; exit 0 ;;
    esac
    snapshot_db
elif [ -n "$INSTALLED_VERSION" ]; then
    info "already at $VERSION - re-running to check and repair"
fi

# ---------------------------------------------------------------- questions
valid_ip() {
    local ip="$1" part
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a part <<< "$ip"
    for n in "${part[@]}"; do [ "$n" -le 255 ] || return 1; done
}

ROLE="${ROLE:-}"; PEER_IP="${PEER_IP:-}"; SELF_IP="${SELF_IP:-}"

if [ -z "$ROLE" ]; then
    printf '\n%sWhich side is this machine?%s\n\n' "$B" "$N"
    printf '  1) relay  - the server inside Iran, the one clients point their DNS at\n'
    printf '  2) exit   - the server abroad, which reaches the blocked sites\n\n'
    while :; do
        read -r -p "  choice [1/2]: " answer
        case "$answer" in
            1|relay) ROLE=relay; break ;;
            2|exit)  ROLE=exit;  break ;;
            *) warn "answer 1 or 2" ;;
        esac
    done
fi
[ "$ROLE" = relay ] || [ "$ROLE" = exit ] || die "ROLE must be relay or exit"

if [ -z "$PEER_IP" ]; then
    printf '\n'
    if [ "$ROLE" = relay ]; then
        read -r -p "  public address of the EXIT server abroad: " PEER_IP
    else
        read -r -p "  public address of the RELAY server in Iran: " PEER_IP
    fi
fi
valid_ip "$PEER_IP" || die "'$PEER_IP' is not an IPv4 address"

if [ -z "$SELF_IP" ]; then
    guess="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
    printf '\n'
    read -r -p "  public address of THIS server [${guess}]: " SELF_IP
    SELF_IP="${SELF_IP:-$guess}"
fi
valid_ip "$SELF_IP" || die "'$SELF_IP' is not an IPv4 address"
[ "$SELF_IP" != "$PEER_IP" ] || die "both addresses are the same"

if [ "$ROLE" = relay ]; then
    RELAY_IP="$SELF_IP"; EXIT_IP="$PEER_IP"
else
    RELAY_IP="$PEER_IP"; EXIT_IP="$SELF_IP"
fi

# ------------------------------------------------------------------ panel
# The panel is optional. Someone who only wants the bypass can leave these
# blank and still get a working pair; the questions are asked here rather than
# halfway through the install so that the whole thing runs unattended after
# this point.
#
# The panel lives on the exit node: it holds the database every relay syncs to,
# and one database is what makes a customer's allowance mean the same thing on
# all of them. The exit builds it unasked; the relay asks for the pairing token
# the exit prints at the end of its own install.
if [ "$ROLE" = relay ] && [ -z "${SYNC_TOKEN:-}" ] && [ -z "${ASSUME_YES:-}" ]; then
    printf '\n%sPanel%s (optional - press enter to skip)\n\n' "$B" "$N"
    printf '  The exit server prints a pairing token at the end of its install.\n'
    read -r -p "  pairing token: " SYNC_TOKEN
fi
# ------------------------------------------------------------------- TLS
# Optional, like the panel. Without it the claim link is plain http, which
# works but sends the registration token in the clear - anyone on the path can
# take it and register their own address against the user's account.
if [ -z "${PANEL_DOMAIN:-}" ] && [ -z "${ASSUME_YES:-}" ]; then
    printf '\n%sHTTPS%s (optional - press enter to skip)\n\n' "$B" "$N"
    if [ "$ROLE" = relay ]; then
        printf '  A name pointing at this machine, for the page users open to\n'
        printf '  register their address.\n'
    else
        printf '  A name pointing at this machine, for the admin panel.\n'
    fi
    read -r -p "  domain: " PANEL_DOMAIN
    # Nothing else is asked. The certificate is obtained automatically and the
    # only thing that proves anything is the domain itself - no DNS token, no
    # account, nothing to hand over.
    if [ -n "$PANEL_DOMAIN" ]; then
        printf '\n  A certificate will be obtained for that name automatically.\n'
        printf '  Point the record at this machine first and leave port 80\n'
        printf '  reachable from the internet - that is how it is checked.\n'
    fi
fi

printf '\n%sAbout to configure:%s\n' "$B" "$N"
printf '    role   : %s\n    relay  : %s\n    exit   : %s\n\n' "$ROLE" "$RELAY_IP" "$EXIT_IP"
if [ -z "${ASSUME_YES:-}" ]; then
    read -r -p "  proceed? [y/N]: " ok
    case "$ok" in y|Y|yes) ;; *) die "cancelled" ;; esac
fi

export DEBIAN_FRONTEND=noninteractive
NGINX_CHANGED=0
DNSMASQ_CHANGED=0

# What the run has to tell the operator at the end. Empty here so that the
# summary can read them plainly under `set -u`, whichever paths ran. One of
# these was left unset when the customer panel stopped being served without a
# certificate, and the install died on its very last line - after doing all of
# its work, and before recording that it had.
ADMIN_URL_OUT=""
ADMIN_PASS_OUT=""
SYNC_TOKEN_OUT=""
USER_PANEL_OUT=""
ENFORCE_OUT=""

# Start the record over, but keep what an earlier install already knew: which
# packages were new and which files existed before we ever touched them. Those
# facts are only true the first time, and losing them would make a later
# uninstall unable to tell "we added this" from "this was already here".
mkdir -p "$STATE_DIR"
# Everything an earlier run recorded, read before the state file is rewritten.
# The record has to survive re-installation: by the second run our own files
# exist and our own services are enabled, so a fresh look at the machine can no
# longer tell our work from the owner's.
PREV_PACKAGES="$(recall_flat packages-installed || true)"
PREV_REPLACED="$(recall_flat files-replaced || true)"
PREV_CREATED="$(recall_flat files-created || true)"
PREV_SERVICES="$(recall_flat services-enabled || true)"
: > "$STATE"
remember role "$ROLE"
remember relay-ip "$RELAY_IP"
remember exit-ip "$EXIT_IP"
remember installed-at "$(date -Is)"

# ---------------------------------------------------------------- packages
step "Installing packages"
if [ "$ROLE" = relay ]; then
    WANT="nginx libnginx-mod-stream dnsmasq coturn nftables dnsutils python3 curl"
else
    WANT="nginx libnginx-mod-stream dnsutils curl python3 openssl"
fi
# Note what was missing beforehand, so uninstall can name exactly what this
# script added rather than offering to purge nginx from a web server.
if [ -n "$PREV_PACKAGES" ]; then
    NEW_PACKAGES="$(echo "$PREV_PACKAGES" | xargs || true)"
else
    NEW_PACKAGES=""
    for pkg in $WANT; do
        dpkg -s "$pkg" >/dev/null 2>&1 || NEW_PACKAGES="$NEW_PACKAGES $pkg"
    done
    NEW_PACKAGES="$(echo "$NEW_PACKAGES" | xargs || true)"
fi
[ -n "$NEW_PACKAGES" ] && remember packages-installed "$NEW_PACKAGES"
apt-get update -qq
# shellcheck disable=SC2086
apt-get install -y -qq $WANT >/dev/null
info "done"

# ---------------------------------------------------------------- kernel
# ------------------------------------------------------------------- swap
# Off unless asked for: SWAP_GB=2 on the command line, or answer the prompt.
# Worth having on a small box - nginx under a console download opens a lot of
# connections at once, and being killed for it is worse than being slow - but
# it is the operator's disk, so it is never created behind their back.
HAVE_SWAP="$(free -m | awk '/Swap/{print $2}')"
if [ -z "${SWAP_GB:-}" ] && [ -z "${ASSUME_YES:-}" ]; then
    if [ "${HAVE_SWAP:-0}" = 0 ]; then
        printf '\n%sThis machine has no swap.%s\n\n' "$B" "$N"
        read -r -p "  create a swap file? size in GB, or enter to skip: " SWAP_GB
    else
        # Say so rather than skipping in silence. An operator who expected a
        # question and got nothing cannot tell "already handled" from "the
        # installer forgot", and will go looking - which is exactly what
        # happened the first time somebody ran this on a machine that had swap.
        step "Swap"
        info "already has ${HAVE_SWAP} MB - leaving it alone"
    fi
fi
if [ -n "${SWAP_GB:-}" ] && [ "${SWAP_GB}" != 0 ]; then
    step "Swap file"
    case "$SWAP_GB" in
        *[!0-9]*|"") die "SWAP_GB must be a whole number of gigabytes" ;;
    esac
    if [ -f /swapfile ]; then
        info "/swapfile already exists - leaving it alone"
    else
        avail="$(df --output=avail -BG / | tail -1 | tr -dc '0-9')"
        [ "${avail:-0}" -gt "$((SWAP_GB + 2))" ] \
            || die "only ${avail}G free on / - not creating a ${SWAP_GB}G swap file"
        # fallocate can produce a sparse file, which the kernel refuses to swap
        # to. dd is slower and correct.
        dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_GB * 1024)) status=none
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile
        note_file /swapfile
        grep -q '^/swapfile ' /etc/fstab 2>/dev/null \
            || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        remember swapfile "/swapfile"
        info "created and enabled ${SWAP_GB}G of swap"
    fi
fi

step "Kernel tuning for the long-RTT link"
install_payload SYSCTL /etc/sysctl.d/99-smartdns-tuning.conf || true
sysctl -p /etc/sysctl.d/99-smartdns-tuning.conf >/dev/null 2>&1 || true

BBR_FILE=/etc/sysctl.d/99-smartdns-bbr.conf
# Congestion control is machine-wide: it changes every connection on the box,
# including services that have nothing to do with this one. So it is asked for
# rather than assumed. On a non-interactive run the existing choice stands,
# which means an upgrade never silently changes how a working server behaves.
if [ -z "${ENABLE_BBR:-}" ]; then
    if [ -n "${ASSUME_YES:-}" ]; then
        # Keep whatever the machine is already doing. The running value matters
        # as much as the file: earlier versions set bbr from the main tuning
        # file, so on those machines there is no bbr file to find, and deciding
        # by the file alone would leave the kernel on bbr now and drop it at
        # the next reboot - a change nobody asked for, appearing days later.
        if [ -f "$BBR_FILE" ] || \
           [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = bbr ]; then
            ENABLE_BBR=yes
        else
            ENABLE_BBR=no
        fi
    else
        printf '\n    %sBBR congestion control%s\n' "$B" "$N"
        printf '    Paces by measured bandwidth instead of backing off on loss.\n'
        printf '    On a %s ms link it is worth a great deal, but it affects every\n' "90"
        printf '    connection on this machine, not only this service.\n\n'
        read -r -p "    enable BBR? [Y/n]: " answer
        case "$answer" in n|N|no) ENABLE_BBR=no ;; *) ENABLE_BBR=yes ;; esac
    fi
fi
case "$ENABLE_BBR" in
    yes|y|1|true)
        install_payload SYSCTL_BBR "$BBR_FILE" || true
        sysctl -p "$BBR_FILE" >/dev/null 2>&1 || true
        ;;
    no|n|0|false)
        rm -f "$BBR_FILE"
        if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = bbr ]; then
            # Only fall back to the kernel default if nothing else on the
            # machine asks for bbr. Someone who set it themselves, in their own
            # file, keeps it - they did not ask this installer to decide.
            if grep -rqs 'tcp_congestion_control' /etc/sysctl.conf /etc/sysctl.d 2>/dev/null; then
                info "BBR left on - another config on this machine sets it"
            else
                sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
                sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
                info "BBR turned off"
            fi
        fi
        ;;
esac
info "congestion=$(sysctl -n net.ipv4.tcp_congestion_control) qdisc=$(sysctl -n net.core.default_qdisc)"

# ---------------------------------------------------------------- nginx
step "nginx"
MOD="$(find /usr/lib/nginx/modules -name ngx_stream_module.so 2>/dev/null | head -1)"
[ -n "$MOD" ] || die "the nginx stream module is missing - libnginx-mod-stream did not install"
info "stream module: $MOD"
if [ "$ROLE" = relay ]; then
    install_payload RELAY_NGINX /etc/nginx/nginx.conf && NGINX_CHANGED=1 || true
else
    install_payload EXIT_NGINX /etc/nginx/nginx.conf && NGINX_CHANGED=1 || true
fi
nginx -t || die "nginx rejected the config; the previous one is in $BACKUP_DIR"
enable_service nginx nginx

# ---------------------------------------------------------------- relay only
if [ "$ROLE" = relay ]; then

    step "dnsmasq: the routed domain list"
    note_file /etc/dnsmasq.d/smart-dns.conf
    tmp="$(mktemp)"
    {
        # No timestamp in here. It would make the file differ on every run, so
        # every run would rewrite it and restart dnsmasq for no reason.
        printf '# generated by the smart-dns installer - do not edit by hand\n'
        printf 'no-resolv\nserver=1.1.1.1\nserver=8.8.8.8\nserver=9.9.9.9\n'
        printf 'cache-size=10000\ndomain-needed\nbogus-priv\nno-hosts\n'
        printf 'bind-interfaces\nlisten-address=127.0.0.1,%s\n\n' "$RELAY_IP"
        printf '# domains answered with this relay, so the traffic leaves via the exit\n'
        payload DOMAINS | while read -r d; do
            [ -n "$d" ] && printf 'address=/%s/%s\n' "$d" "$RELAY_IP"
        done
    } > "$tmp"
    if [ -f /etc/dnsmasq.d/smart-dns.conf ] && cmp -s "$tmp" /etc/dnsmasq.d/smart-dns.conf; then
        rm -f "$tmp"; info "unchanged ($(grep -c '^address=' /etc/dnsmasq.d/smart-dns.conf) domains)"
    else
        backup_file /etc/dnsmasq.d/smart-dns.conf
        mv "$tmp" /etc/dnsmasq.d/smart-dns.conf; chmod 644 /etc/dnsmasq.d/smart-dns.conf
        info "wrote $(grep -c '^address=' /etc/dnsmasq.d/smart-dns.conf) domains"
        DNSMASQ_CHANGED=1
    fi

    step "dnsmasq: names that must NOT be routed"
    install_payload BYPASS /etc/dnsmasq.d/bypass.conf && DNSMASQ_CHANGED=1 || true
    rm -f /etc/dnsmasq.d/ea-bypass.conf   # superseded filename from an earlier build

    step "dnsmasq: stop AAAA answers routing clients around us"
    install_payload NO_AAAA /etc/dnsmasq.d/no-aaaa.conf && DNSMASQ_CHANGED=1 || true

    dnsmasq --test -C /etc/dnsmasq.conf || die "dnsmasq rejected the config"
    enable_service dnsmasq dnsmasq

    step "STUN server, so consoles can still detect their NAT"
    install_payload TURNSERVER /etc/turnserver.conf || true
    grep -q '^TURNSERVER_ENABLED=1' /etc/default/coturn 2>/dev/null \
        || echo 'TURNSERVER_ENABLED=1' >> /etc/default/coturn
    enable_service coturn coturn
    systemctl restart coturn || warn "coturn did not start; STUN will be unavailable"

    step "Firewall: rate limit, access control and traffic accounting"
    export PATH="$PATH:/usr/sbin"
    mkdir -p /etc/nftables.d
    # An earlier version of this installer built the table with a series of
    # `nft add` commands and dumped the result here. That file is a complete
    # table definition, so leaving it in place would load a second copy of
    # every chain alongside the one below.
    if [ -f /etc/nftables.d/smartdns.conf ]; then
        backup_file /etc/nftables.d/smartdns.conf
        rm -f /etc/nftables.d/smartdns.conf
        info "removed the ruleset from the previous layout"
    fi
    grep -q 'nftables.d' /etc/nftables.conf 2>/dev/null \
        || echo 'include "/etc/nftables.d/*.conf"' >> /etc/nftables.conf

    install_payload NFTABLES /etc/nftables.d/10-smartdns.conf && NFT_CHANGED=1 || NFT_CHANGED=0
    # Reload only when the structure actually changed, or when the table is
    # missing entirely. Loading it on every run would append a duplicate of
    # every rule; rebuilding the table on every run would throw away the
    # allowlist and everybody's usage along with it.
    if [ "$NFT_CHANGED" = 1 ] || ! nft list table inet smartdns >/dev/null 2>&1; then
        [ -x /usr/local/bin/smartdns-acl ] && /usr/local/bin/smartdns-acl save 2>/dev/null
        nft delete table inet smartdns 2>/dev/null || true
        nft -f /etc/nftables.d/10-smartdns.conf || die "nft rejected the ruleset"
        # Structure first, then whoever was registered before it, then the
        # access rules if this machine had them switched on.
        [ -f /etc/nftables.d/20-smartdns-state.conf ] \
            && { nft -f /etc/nftables.d/20-smartdns-state.conf || warn "could not restore the allowlist"; }
        [ -f /etc/nftables.d/30-smartdns-enforce.conf ] \
            && { nft -f /etc/nftables.d/30-smartdns-enforce.conf || warn "could not restore the access rules"; }
        info "ruleset loaded"
    else
        info "ruleset already current"
    fi
    enable_service nftables nftables

    step "smartdns-acl command, for access control and usage"
    note_file /usr/local/bin/smartdns-acl
    payload SMARTDNS_ACL > /usr/local/bin/smartdns-acl
    chmod +x /usr/local/bin/smartdns-acl
    install_payload ACL_SAVE_SERVICE /etc/systemd/system/smartdns-acl-save.service || true
    install_payload ACL_SAVE_TIMER   /etc/systemd/system/smartdns-acl-save.timer   || true
    systemctl daemon-reload
    enable_service smartdns-acl-save.timer
    systemctl start smartdns-acl-save.timer 2>/dev/null || true
    # Counting starts now; blocking does not. Nobody has registered an address
    # yet, so switching enforcement on at this point would cut off every user
    # of the relay, including whoever is running this.
    info "counting usage - nothing is blocked yet"

    step "smartdns-shape command, for per-customer speed limits"
    note_file /usr/local/bin/smartdns-shape
    payload SMARTDNS_SHAPE > /usr/local/bin/smartdns-shape
    chmod +x /usr/local/bin/smartdns-shape
    # Nothing is shaped until a customer is actually given a limit; the sync
    # agent calls this when the panel says somebody has one.
    if ! modprobe sch_htb 2>/dev/null; then
        warn "this kernel has no htb - speed limits will not work here"
    fi
    info "no limits set - customers run at line rate until you set one"

    step "smartdns command"
    note_file /usr/local/bin/smartdns
    payload SMARTDNS | sed "s#__RELAY_IP__#${RELAY_IP}#g" > /usr/local/bin/smartdns
    chmod +x /usr/local/bin/smartdns
    info "try: smartdns status"

    step "epic-pin, keeping Epic's backend on addresses that answer from here"
    # epic-pins.conf is written later by epic-pin itself, but it is ours either
    # way and uninstall needs to know to take it with us.
    for f in /usr/local/bin/epic-pin \
             /etc/systemd/system/epic-pin.service \
             /etc/systemd/system/epic-pin.timer \
             /etc/dnsmasq.d/epic-pins.conf
    do
        note_file "$f"
    done
    payload EPIC_PIN > /usr/local/bin/epic-pin
    chmod +x /usr/local/bin/epic-pin
    payload EPIC_PIN_SERVICE > /etc/systemd/system/epic-pin.service
    payload EPIC_PIN_TIMER   > /etc/systemd/system/epic-pin.timer
    systemctl daemon-reload
    enable_service epic-pin.timer
    systemctl start epic-pin.timer  >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------- TLS
# A machine that already has a domain keeps it, even when this run was not
# told one. Everything below is gated on PANEL_DOMAIN - the certificate, its
# renewal timer, the admin panel and its restart - so an upgrade that did not
# repeat the domain skipped all of it and still ended by announcing a
# successful upgrade. The operator is then left on the previous version of the
# one page they actually use, with nothing said. That is not hypothetical: it
# happened here, and the symptom was an admin panel showing a stale service
# catalogue and a stale warning under every group in it.
#
# The state file is no help - it is truncated at the start of every run - so
# the answer has to come from something the machine keeps for its own sake.
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
if [ -z "$PANEL_DOMAIN" ]; then
    if [ -f /etc/smart-dns/sync.env ]; then
        PANEL_DOMAIN="$(sed -n 's/^PANEL_DOMAIN=//p' /etc/smart-dns/sync.env \
                        | head -1 || true)"
    fi
    # The exit keeps no sync.env. Its admin.env records where the certificate
    # is, and that path is /etc/letsencrypt/live/<domain>/fullchain.pem.
    if [ -z "$PANEL_DOMAIN" ] && [ -f /etc/smart-dns/admin.env ]; then
        PANEL_DOMAIN="$(sed -n \
            's#^ADMIN_CERT=/etc/letsencrypt/live/\([^/]*\)/.*#\1#p' \
            /etc/smart-dns/admin.env | head -1 || true)"
    fi
    if [ -n "$PANEL_DOMAIN" ]; then
        info "keeping the domain this machine already has: $PANEL_DOMAIN"
    fi
fi

# The helper goes on every machine, domain or no domain. Without one this run
# installs no certificate - but the summary at the end tells the operator to
# come back and run this command once they have a name, and a command that is
# only installed when it is not needed is not much of an instruction.
payload CERT > /usr/local/bin/smartdns-cert
chmod +x /usr/local/bin/smartdns-cert
note_file /usr/local/bin/smartdns-cert
install_payload CERT_SERVICE /etc/systemd/system/smartdns-cert.service || true
install_payload CERT_TIMER   /etc/systemd/system/smartdns-cert.timer   || true
systemctl daemon-reload

if [ -n "${PANEL_DOMAIN:-}" ]; then
    step "HTTPS certificate for $PANEL_DOMAIN"
    CERT_PKGS="certbot"
    [ -f /etc/smart-dns/cloudflare.ini ] && CERT_PKGS="$CERT_PKGS python3-certbot-dns-cloudflare"
    for pkg in $([ -z "${PANEL_CERT:-}" ] && echo $CERT_PKGS); do
        dpkg -s "$pkg" >/dev/null 2>&1 || {
            apt-get install -y -qq "$pkg" >/dev/null 2>&1 || die "could not install $pkg"
            NEW_PACKAGES="$NEW_PACKAGES $pkg"
            remember packages-installed "$pkg"
        }
    done

    mkdir -p /etc/smart-dns; chmod 700 /etc/smart-dns

    # A certificate the operator obtained themselves. Recorded and used as-is;
    # keeping it renewed is then their business, which is the trade they made
    # by not handing over a DNS token.
    if [ -n "${PANEL_CERT:-}" ]; then
        [ -f "$PANEL_CERT" ] || die "no certificate at $PANEL_CERT"
        [ -f "${PANEL_KEY:-}" ] || die "no private key at ${PANEL_KEY:-<not given>}"
        CERT_PATH="$PANEL_CERT"; KEY_PATH="$PANEL_KEY"
        info "using the certificate you supplied"
        # Nothing here renews it, so say how long it has. A panel that stops
        # answering in two months with no warning is a bad way to find out.
        if openssl x509 -checkend $((30 * 86400)) -noout -in "$CERT_PATH" >/dev/null 2>&1; then
            info "valid until $(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)"
        else
            warn "this certificate expires within 30 days - nothing here renews it"
        fi
    else
        # certbot's own. It proves the domain over port 80 by default, which
        # needs nothing from the operator but a record pointing here. A token
        # left in cloudflare.ini switches it to DNS instead, but nothing asks
        # for one and nothing needs one.
        if [ -n "${CF_API_TOKEN:-}" ]; then
            umask 077
            printf 'dns_cloudflare_api_token = %s\n' "$CF_API_TOKEN" \
                > /etc/smart-dns/cloudflare.ini
            umask 022
            chmod 600 /etc/smart-dns/cloudflare.ini
        fi
        CERT_PATH="/etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem"
        KEY_PATH="/etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem"
    fi

    if [ -z "${PANEL_CERT:-}" ]; then
        /usr/local/bin/smartdns-cert "$PANEL_DOMAIN" || die "could not get a certificate"
        # Only once there is something to renew. A timer running against no
        # certificate is a unit that wakes twice a day to do nothing.
        enable_service smartdns-cert.timer
        systemctl start smartdns-cert.timer 2>/dev/null || true
    fi
    [ -f "$CERT_PATH" ] || die "still no certificate at $CERT_PATH"
    remember panel-domain "$PANEL_DOMAIN"
fi

# ----------------------------------------------------------------- panel
if [ "$ROLE" = exit ]; then
    step "Panel: database and sync API"
    mkdir -p /etc/smart-dns; chmod 700 /etc/smart-dns

    # The relay authenticates this machine by the fingerprint of this
    # certificate, so it must survive re-runs: generating a new one would
    # silently break the pairing and the relay would refuse to talk.
    if [ ! -f /etc/smart-dns/sync.key ]; then
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -subj "/CN=smartdns-sync" \
            -keyout /etc/smart-dns/sync.key -out /etc/smart-dns/sync.crt \
            >/dev/null 2>&1 || die "could not generate the sync certificate"
        chmod 600 /etc/smart-dns/sync.key
        info "generated the sync certificate"
    fi
    # Same for the shared secret. Re-running the installer must not unpair a
    # relay that is working.
    # `|| true` again: on the first install panel.env does not exist, sed exits
    # non-zero, and under `set -e` with pipefail that ends the installer right
    # here without printing anything.
    SYNC_SECRET="$(sed -n 's/^SYNC_SECRET=//p' /etc/smart-dns/panel.env 2>/dev/null | head -1 || true)"
    [ -n "$SYNC_SECRET" ] || SYNC_SECRET="$(openssl rand -hex 24)"

    umask 077
    if [ ! -f /etc/smart-dns/panel.env ]; then
        cat > /etc/smart-dns/panel.env <<EOF
# Secrets and panel settings. Not in git and not in the installer: this file is
# written at install time and is readable only by root.
SYNC_SECRET=$SYNC_SECRET
RELAY_IP=$RELAY_IP
EOF
    else
        # Merge rather than rewrite. An earlier version of this rewrote the
        # whole file on every run, which silently undid the operator's own
        # settings - a second relay added to RELAY_IP, a CLAIM_HOST - and the
        # only symptom was the other relay suddenly getting 401s.
        # RELAY_IP is a list, and this relay may already be on it or may be a
        # new one joining. Adding is right; replacing would unpair the others.
        current_relays="$(sed -n 's/^RELAY_IP=//p' /etc/smart-dns/panel.env | head -1 || true)"
        case ",${current_relays}," in
            *",$RELAY_IP,"*) ;;
            *) set_env_key /etc/smart-dns/panel.env RELAY_IP \
                   "${current_relays:+$current_relays,}$RELAY_IP"
               info "added $RELAY_IP to the relays this panel serves" ;;
        esac
    fi
    umask 022
    chmod 600 /etc/smart-dns/panel.env

    payload PANEL > /usr/local/bin/smartdns-panel
    chmod +x /usr/local/bin/smartdns-panel
    note_file /usr/local/bin/smartdns-panel
    # The service catalogue: which brands exist, and which domains are in each
    # group. Shipped as a file so it is versioned with the code rather than
    # migrated into the database.
    mkdir -p /usr/local/share/smart-dns
    note_file /usr/local/share/smart-dns/services.json
    payload SERVICES > /usr/local/share/smart-dns/services.json
    install_payload PANEL_SERVICE /etc/systemd/system/smartdns-panel.service || true
    systemctl daemon-reload
    enable_service smartdns-panel.service
    systemctl restart smartdns-panel.service
    sleep 2
    if systemctl is-active --quiet smartdns-panel.service; then
        info "sync API is up on :8443"
    else
        warn "the panel did not start - journalctl -u smartdns-panel"
    fi

    # ---- admin web panel -------------------------------------------------
    if [ -n "${PANEL_DOMAIN:-}" ]; then
        step "Admin web panel"
        payload ADMIN > /usr/local/bin/smartdns-admin
        chmod +x /usr/local/bin/smartdns-admin
        note_file /usr/local/bin/smartdns-admin
        install_payload ADMIN_SERVICE /etc/systemd/system/smartdns-admin.service || true

        payload SMARTDNS_ACCESS > /usr/local/bin/smartdns-access
        chmod +x /usr/local/bin/smartdns-access
        note_file /usr/local/bin/smartdns-access

        # Generated once and kept. Regenerating on every run would move the URL
        # and change the password under the operator each time they upgraded.
        if [ ! -f /etc/smart-dns/admin.env ]; then
            # Asked for, not assumed. The port is the operator's firewall to
            # think about, and a password they chose is one they will still
            # have tomorrow - a generated one gets pasted somewhere careless
            # or lost. Both have answers, so pressing enter is fine.
            if [ -z "${ASSUME_YES:-}" ]; then
                printf '\n%sAdmin panel%s\n\n' "$B" "$N"
                if [ -z "${ADMIN_PORT:-}" ]; then
                    # Said before the question rather than after a rejected
                    # answer: an operator who has already typed 443 has
                    # usually also written it into a firewall rule.
                    warn "these ports are taken - do not pick one of them:"
                    warn "    22    ssh"
                    warn "    53    dns"
                    warn "    80    the proxy, and how certificates are proved"
                    warn "   443    the proxy"
                    warn "  8443    the sync API the relays connect to"
                    warn "on a relay, 3478 is taken as well."
                    warn "pick anything else, and open it in your firewall."
                    printf '\n'
                    read -r -p "  port to serve it on [9443]: " ADMIN_PORT
                fi
                if [ -z "${ADMIN_PASS:-}" ]; then
                    printf '  password [enter for a generated one]: '
                    read -rs ADMIN_PASS; printf '\n'
                    if [ -n "$ADMIN_PASS" ]; then
                        printf '  again: '
                        read -rs ADMIN_PASS2; printf '\n'
                        [ "$ADMIN_PASS" = "$ADMIN_PASS2" ] \
                            || die "the two passwords did not match"
                        [ "${#ADMIN_PASS}" -ge 8 ] \
                            || die "use a password of 8 characters or more"
                    fi
                fi
            fi
            ADMIN_PORT="${ADMIN_PORT:-9443}"
            case "$ADMIN_PORT" in
                *[!0-9]*|"") die "the admin port must be a number" ;;
                22) die "port 22 is ssh" ;;
                8443) die "port 8443 is the sync API the relays connect to" ;;
                53|80|443) die "port $ADMIN_PORT is the service's own - pick
    another. 22, 53, 80, 443 and 8443 are all taken." ;;
            esac
            # The path stays generated. Nobody types it from memory, and an
            # operator asked to invent one invents a guessable one.
            [ -n "${ADMIN_PASS:-}" ] \
                || ADMIN_PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-16)"
            ADMIN_SALT="$(openssl rand -hex 16)"
            ADMIN_HASH="$(ADMIN_PASS="$ADMIN_PASS" ADMIN_SALT="$ADMIN_SALT" python3 -c '
import hashlib, os
print(hashlib.pbkdf2_hmac("sha256", os.environ["ADMIN_PASS"].encode(),
                          bytes.fromhex(os.environ["ADMIN_SALT"]), 200000).hex())')"
            ADMIN_PATH_GEN="$(openssl rand -hex 12)"
            umask 077
            cat > /etc/smart-dns/admin.env <<EOF
# Written once at install. The password itself is not stored - only a salted
# hash - so a forgotten password is replaced, never recovered.
ADMIN_PORT=$ADMIN_PORT
ADMIN_PATH=$ADMIN_PATH_GEN
ADMIN_SALT=$ADMIN_SALT
ADMIN_HASH=$ADMIN_HASH
ADMIN_CERT=$CERT_PATH
ADMIN_KEY=$KEY_PATH
EOF
            umask 022
            chmod 600 /etc/smart-dns/admin.env
            ADMIN_URL_OUT="https://$PANEL_DOMAIN:$ADMIN_PORT/$ADMIN_PATH_GEN/"
            ADMIN_PASS_OUT="$ADMIN_PASS"
        else
            info "keeping the admin URL and password already set up here"
            info "change them with: smartdns-access"
        fi
        systemctl daemon-reload
        enable_service smartdns-admin.service
        systemctl restart smartdns-admin.service
        sleep 2
        if systemctl is-active --quiet smartdns-admin.service; then
            info "admin panel running"
        else
            warn "the admin panel did not start - journalctl -u smartdns-admin"
        fi
    fi

    FP="$(openssl x509 -in /etc/smart-dns/sync.crt -noout -fingerprint -sha256 \
          | cut -d= -f2 | tr -d ':' | tr 'A-Z' 'a-z')"
    SYNC_TOKEN_OUT="$SYNC_SECRET.$FP"
fi

# A relay that is already paired keeps its pairing. Requiring the token again
# on every run meant an upgrade run without it skipped this whole section and
# silently left the old agent in place - the machine kept syncing, so nothing
# looked wrong, while the new code never arrived.
if [ "$ROLE" = relay ] && [ -z "${SYNC_TOKEN:-}" ] && [ -f /etc/smart-dns/sync.env ]; then
    SYNC_TOKEN="$(sed -n 's/^SYNC_SECRET=//p' /etc/smart-dns/sync.env | head -1 || true).$(sed -n 's/^SYNC_FINGERPRINT=//p' /etc/smart-dns/sync.env | head -1 || true)"
    PANEL_IP="${PANEL_IP:-$(sed -n 's/^PANEL_HOST=//p' /etc/smart-dns/sync.env | head -1 || true)}"
    KEEP_PAIRING=1
fi

if [ "$ROLE" = relay ] && [ -n "${SYNC_TOKEN:-}" ]; then
    step "Panel: sync agent and claim page"
    # secret.fingerprint - one string for the user to copy, carrying both the
    # shared secret and the certificate to pin. Splitting them into two
    # questions only creates a chance to paste one and forget the other.
    SECRET="${SYNC_TOKEN%%.*}"
    FINGER="${SYNC_TOKEN##*.}"
    [ -n "$SECRET" ] && [ -n "$FINGER" ] && [ "$SECRET" != "$FINGER" ] \
        || die "that does not look like a pairing token.
    It is the whole 'secret.fingerprint' line the exit server printed."
    case "$FINGER" in
        *[!0-9a-f]*|"") die "the fingerprint half of the token is not hexadecimal" ;;
    esac
    [ -n "${KEEP_PAIRING:-}" ] && info "keeping the pairing already on this machine"

    # Usually the panel lives on this relay's own exit, but it need not: one
    # database can serve several relay/exit pairs, and one database is what
    # makes a customer's allowance mean the same thing on all of them.
    # PANEL_IP names the machine running the panel when it is a different one.
    PANEL_HOST="${PANEL_IP:-$EXIT_IP}"
    valid_ip "$PANEL_HOST" || die "PANEL_IP '$PANEL_HOST' is not an IPv4 address"

    mkdir -p /etc/smart-dns; chmod 700 /etc/smart-dns
    # Recover the domain this relay already serves its panel on, if this run
    # was not told one. Without this, re-running the installer and pressing
    # enter at the domain prompt blanked PANEL_DOMAIN, and the customer panel
    # silently dropped from https to plain http - which also switches sign-up
    # off. The same trap that once rewrote panel.env on the exit.
    if [ -z "${PANEL_DOMAIN:-}" ] && [ -f /etc/smart-dns/sync.env ]; then
        PANEL_DOMAIN="$(sed -n 's/^PANEL_DOMAIN=//p' /etc/smart-dns/sync.env | head -1 || true)"
        [ -n "$PANEL_DOMAIN" ] && info "keeping the panel domain already set: $PANEL_DOMAIN"
    fi
    umask 077
    if [ ! -f /etc/smart-dns/sync.env ]; then
        cat > /etc/smart-dns/sync.env <<EOF
PANEL_HOST=$PANEL_HOST
SYNC_SECRET=$SECRET
SYNC_FINGERPRINT=$FINGER
SELF_IP=$RELAY_IP
PANEL_DOMAIN=${PANEL_DOMAIN:-}
EOF
    else
        # Merge, so anything the operator added by hand survives an upgrade.
        set_env_key /etc/smart-dns/sync.env PANEL_HOST "$PANEL_HOST"
        set_env_key /etc/smart-dns/sync.env SYNC_SECRET "$SECRET"
        set_env_key /etc/smart-dns/sync.env SYNC_FINGERPRINT "$FINGER"
        set_env_key /etc/smart-dns/sync.env SELF_IP "$RELAY_IP"
        set_env_key /etc/smart-dns/sync.env PANEL_DOMAIN "${PANEL_DOMAIN:-}"
    fi
    umask 022
    chmod 600 /etc/smart-dns/sync.env

    payload SYNC > /usr/local/bin/smartdns-sync
    chmod +x /usr/local/bin/smartdns-sync
    note_file /usr/local/bin/smartdns-sync
    # A systemd template, one instance per service profile. The instances
    # themselves are started and stopped by the sync agent as the panel adds
    # and retires templates, so nothing here is enabled.
    install_payload DNS_PROFILE_UNIT /etc/systemd/system/smartdns-dns@.service || true
    mkdir -p /etc/smartdns-profiles
    install_payload SYNC_SERVICE /etc/systemd/system/smartdns-sync.service || true
    systemctl daemon-reload
    enable_service smartdns-sync.service
    systemctl restart smartdns-sync.service
    sleep 3
    # Where the customer's panel ended up, for the summary at the end. It is
    # served over TLS or not at all - it asks for a password, and there is no
    # safe way to do that in the clear - so a relay with no certificate has no
    # panel and nothing to print. 8443 sits outside the gated ports on purpose,
    # so somebody whose address changed can still reach the page that fixes it.
    if [ -n "${PANEL_DOMAIN:-}" ]; then
        USER_PANEL_OUT="https://$PANEL_DOMAIN:8443/"
    fi
    # Closed from the moment it is installed. This used to wait for the first
    # customer to register before shutting the door, on the reasoning that
    # enforcing against an empty allowlist cuts everyone off - but on a fresh
    # relay there is nobody to cut off, and what "waiting" really means is a
    # relay that anybody who learns its address can use for free, for as long
    # as it takes somebody to notice.
    #
    # Nothing here is at risk from it. SSH is never gated, the customer panel
    # is on a port the gate does not touch, and the certificate challenge is
    # redirected in prerouting so it reaches certbot before the gate ever sees
    # a packet on 80.
    rm -f /etc/smart-dns/auto-enforce
    if [ "${ENFORCE:-yes}" = no ]; then
        info "ENFORCE=no - this relay is open to everyone until you close it:"
        info "    smartdns-acl enforce on"
    elif smartdns-acl enforce on --yes --allow-empty >/dev/null 2>&1; then
        ENFORCE_OUT=1
        info "access control is on - only registered addresses get through"
    else
        warn "could not switch access control on - this relay is open."
        warn "close it by hand once you have looked:  smartdns-acl enforce on"
    fi
    if systemctl is-active --quiet smartdns-sync.service; then
        info "syncing with the panel at $PANEL_HOST every 30s"
        if [ -n "$USER_PANEL_OUT" ]; then
            info "customer panel on $USER_PANEL_OUT"
        else
            warn "no certificate, so no customer panel - see the end of this run"
        fi
    else
        warn "the sync agent did not start - journalctl -u smartdns-sync"
    fi
fi

# ---------------------------------------------------------------- start
step "Starting services"
if [ "$NGINX_CHANGED" = 1 ]; then systemctl restart nginx
else systemctl reload nginx 2>/dev/null || systemctl start nginx; fi
if [ "$ROLE" = relay ]; then
    if [ "$DNSMASQ_CHANGED" = 1 ]; then systemctl restart dnsmasq
    else systemctl start dnsmasq 2>/dev/null || true; fi
    /usr/local/bin/epic-pin || warn "epic-pin failed this run; the timer will retry"
fi

# ---------------------------------------------------------------- verify
step "Checking"
fail=0
check() {
    if [ "$2" = "$3" ]; then printf '    %s.%s %s\n' "$G" "$N" "$1"
    else printf '    %sx%s %s  (got: %s)\n' "$RD" "$N" "$1" "$2"; fail=1; fi
}
check "nginx running" "$(systemctl is-active nginx)" active
if [ "$ROLE" = relay ]; then
    check "dnsmasq running" "$(systemctl is-active dnsmasq)" active
    check "coturn running"  "$(systemctl is-active coturn)"  active
    check "a routed domain resolves to this relay" \
          "$(dig +short +time=3 @127.0.0.1 github.com A 2>/dev/null | tail -1)" "$RELAY_IP"
    check "no IPv6 answers leak around the relay" \
          "$(dig +short +time=3 @127.0.0.1 github.com AAAA 2>/dev/null | grep -c ':' || true)" "0"
    # Two things, not one. A domain we do not route has to answer, and has to
    # answer with somebody else's address. Counting its records was wrong:
    # example.com has more than one, and how many is not ours to assert.
    unrouted="$(dig +short +time=3 @127.0.0.1 example.com A 2>/dev/null)"
    check "an unrouted domain still resolves" \
          "$([ -n "$unrouted" ] && echo yes || echo no)" "yes"
    # example.com is the sentinel because it is stable and nobody needs it
    # bypassed - but an operator can add anything to their own routed list, so
    # a failure here is as likely to mean "you added this on purpose" as it is
    # to mean something is wrong. Say which name it used, so the answer is in
    # the message rather than in a debugging session.
    if [ "$(printf '%s\n' "$unrouted" | grep -c "^${RELAY_IP}$" || true)" != 0 ]; then
        warn "example.com resolves to this relay, so it is being routed."
        warn "That is only a problem if you did not mean it - check with:"
        warn "    grep -rn example.com /etc/dnsmasq.d/"
    fi
    check "an unrouted domain is not pointed at this relay" \
          "$(printf '%s\n' "$unrouted" | grep -c "^${RELAY_IP}$" || true)" "0"
    check "a site loads through the full chain" \
          "$(curl -sS -o /dev/null -m 25 --resolve "github.com:443:${RELAY_IP}" -w '%{http_code}' https://github.com/ 2>/dev/null || echo 000)" "200"
fi

printf '\n'
if [ "$fail" = 0 ]; then
    # Written here and nowhere earlier: a run that died half way through has
    # not installed this version, and recording it would tell the next run
    # there was nothing left to do.
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$VERSION" > "$VERSION_FILE"
    printf '%s%s is installed and working, version %s.%s\n' \
           "$G" "$ROLE" "$VERSION" "$N"
else
    printf '%sSomething is off - see the failures above.%s\n' "$Y" "$N"
fi

if [ "$ROLE" = relay ]; then
    printf '
    Point your devices at this address for DNS:

        %s

    Set it as both primary and secondary. A different secondary is worse than
    none: the device will sometimes use it and quietly skip the bypass.

    Manage the list with:  smartdns status | list | add | del | bypass

' "$RELAY_IP"
else
    printf '
    This exit only accepts connections from %s, so it is not an open proxy.
    Run the installer on the relay next, if you have not already.

' "$RELAY_IP"
fi

if [ -n "$ENFORCE_OUT" ]; then
    printf '    %sAccess control is on%s - only addresses registered in the panel get
    DNS, HTTP and HTTPS through this relay. Nobody is registered yet, so right
    now that is nobody: sign a customer up, give them a plan, and let them
    register their address from the customer panel.

    SSH is never gated, and the customer panel is on a port the gate does not
    touch - so a wrong allowlist cannot lock you out of either.

        smartdns-acl list               who is allowed, and what they have used
        smartdns-acl enforce status     which way the door is
        smartdns-acl enforce off        open it to everyone

' "$B" "$N"
fi

if [ -n "$USER_PANEL_OUT" ]; then
    printf '    %sCustomer panel%s - where people sign up, register the address the
    service works on, see what is left of their allowance, and send a payment
    receipt. It also shows them the DNS address to enter.

        %s

' "$B" "$N" "$USER_PANEL_OUT"
fi

if [ "$ROLE" = relay ] && [ -z "${PANEL_DOMAIN:-}" ]; then
    printf '    %sThere is no customer panel on this relay%s, because it has no
    certificate. That page asks for a password, and nothing asks for a
    password over plain http here - so it is not served at all rather than
    served unsafely. Nobody can sign up or register an address until you
    give this machine a domain:

        smartdns-cert panel.example.com

    then put PANEL_DOMAIN in /etc/smart-dns/sync.env and restart
    smartdns-sync.

' "$Y" "$N"
fi

if [ -n "$ADMIN_URL_OUT" ]; then
    printf '    %sAdmin panel%s - shown once. Only a hash of the password is stored,
    so it can be replaced but never read back. Write it down now.

        %s
        password: %s

' "$B" "$N" "$ADMIN_URL_OUT" "$ADMIN_PASS_OUT"
fi

if [ -n "$SYNC_TOKEN_OUT" ]; then
    printf '    %sPairing token%s - run the installer on the relay and paste this when
    it asks. It carries both the shared secret and the fingerprint of this
    machine'"'"'s certificate, so the relay will talk to this server and no other.

        %s

' "$B" "$N" "$SYNC_TOKEN_OUT"
fi

exit 0

# ====================================================================
# Config payloads. Everything below is data, never executed.
# ====================================================================

#__BEGIN_SYSCTL__
## /etc/sysctl.d/99-smartdns-tuning.conf
##
## Tuning for a relay whose upstream leg is a 90 ms Iran -> Frankfurt hop.
## The RTT itself cannot be reduced - a traceroute shows one clean hop from the
## Iranian edge to DE-CIX Frankfurt at 89 ms, with 0% loss and 0.4 ms jitter,
## and every other exit region measured from this box is the same or worse
## (UAE 110 ms, Mumbai 203 ms). What is left to win is throughput, which the
## stock settings throttle badly at this bandwidth-delay product.
#
## Congestion control is NOT set here. BBR helps this workload a great deal, but
## it changes how every connection on the machine behaves, including services
## that have nothing to do with this one - so it is asked for rather than
## assumed, and lives in its own file the installer writes only on request.
#
## At 90 ms RTT a socket needs ~11 MB in flight to fill a 1 Gbit/s path. The
## stock 4 MB write buffer caps a single stream well below that.
#net.core.rmem_max = 33554432
#net.core.wmem_max = 33554432
#net.ipv4.tcp_rmem = 4096 131072 33554432
#net.ipv4.tcp_wmem = 4096 65536 33554432
#
## A relay's connections go idle between bursts. Restarting slow start each time
## costs several RTTs - at 90 ms that is very visible on page loads.
#net.ipv4.tcp_slow_start_after_idle = 0
#
## Find the real path MTU instead of stalling on a black-holed ICMP.
#net.ipv4.tcp_mtu_probing = 1
#
## Saves one full RTT on connection setup where both ends support it.
#net.ipv4.tcp_fastopen = 3
#
## Accept queues sized for many short-lived proxied connections.
#net.core.netdev_max_backlog = 16384
#net.core.somaxconn = 8192
#net.ipv4.tcp_max_syn_backlog = 8192
#net.ipv4.tcp_fin_timeout = 15
#net.ipv4.tcp_tw_reuse = 1
#__END_SYSCTL__

#__BEGIN_SYSCTL_BBR__
## /etc/sysctl.d/99-smartdns-bbr.conf
##
## Written only when the operator asks for it, because congestion control is
## machine-wide: it changes every connection on the box, not just this service's.
##
## For this workload it is the single most useful setting there is. The upstream
## leg is a 90 ms Iran -> Frankfurt hop, and the stock algorithm reads loss as
## congestion and backs off - on a long fat pipe that leaves most of the
## capacity unused. BBR paces by measured bandwidth instead, and fq is the
## queueing discipline it expects.
##
## Remove this file and reboot, or re-run the installer and answer no, to go
## back to the kernel default.
#net.core.default_qdisc = fq
#net.ipv4.tcp_congestion_control = bbr
#__END_SYSCTL_BBR__

#__BEGIN_BYPASS__
## /etc/dnsmasq.d/bypass.conf
##
## Names that must NOT be hijacked, even though a parent domain is routed.
## dnsmasq resolves by longest match, so these win over address=/<parent>/...
##
## Two separate reasons a name lands here. Both were found in real packet
## captures, and each cost a broken game before it was understood.
##
## 1. The service is not on TCP 443. The relay listens only on 80 and 443, so
##    pointing such a name at it makes the client fire SYNs into a void and retry
##    forever. EA's game stack is full of these:
##
##      gosredirector.ea.com   TCP 42130 / 42230   game-server redirector
##      blaze.ea.com           TCP 15000-15100     the actual game servers
##      gameservices.ea.com    TCP 10010, 11000    QoS coordinator, match stats
##      tnt-ea.com             TCP 8095            realtime messaging
##
## 2. The service is reachable from Iran anyway, and routing it costs something.
##    ps5.np.playstation.net is the console's STUN server as well as a PSN API
##    host, and it answers fine from an Iranian address - routing it sent NAT
##    detection to our own single-homed coturn instead of Sony's pair, which
##    cannot classify the NAT properly. Only gst.prod.dl.playstation.net actually
##    needs the exit (it does not complete TLS from Iran at all); the rest of
##    prod.dl and the playstation.com API stay routed with it.
##
##      np.playstation.net      ps5.np - STUN + PSN API
##      np.dl.playstation.net   envelope2, uef, gs-sec.ww
##
##    The same reasoning was tried for Epic's backend and reverted - see below -
##    so verify per-name rather than assuming the rule generalises.
##
##    Epic's game backend is the other case, and the important one. Fortnite gets
##    into a match when ol.epicgames.com and friends resolve directly, and does
##    not when they are routed - matchmaking has to come from the same address the
##    console later plays from, or the game server ignores the gameplay packets.
##
##    I reverted this once on the strength of a capture that seemed to disprove
##    it. The capture was confounded: the bypass had left the console on an Epic
##    address that is unreachable from Iran, so the test failed for an unrelated
##    reason. Epic round-robins each name across many addresses and a few are
##    dead from here - one in thirty-three when sampled - which is why Fortnite
##    worked on some attempts and not others. epic-pin handles that by probing
##    each address and pinning only the ones that answer.
##
##      ol.epicgames.com                   account, fortnite, datarouter, fngw
##      ogs.live.on.epicgames.com          habanero, discovery
##      edea.live.use1a.on.epicgames.com   prm-dialogue
##
##    Still routed on purpose: epicgames.com itself (www and store are 403 from
##    Iran), cdn2.unrealengine.com and cdn-0001.qstv.on.epicgames.com.
##
##    core.windows.net is a third kind again: routing it is *demonstrably* broken.
##    A ClientHello for any *.core.windows.net name arrives at the exit with the SNI
##    missing - nginx logged sni="-" and dropped it - while an equally long test
##    hostname and every other domain came through intact. Something on the
##    Iran->exit leg mangles those particular handshakes. The same host answers 400
##    when reached directly from the relay, so direct beats routed here.
##
## Add more with:  smartdns bypass <domain>
#
#server=/gosredirector.ea.com/1.1.1.1
#server=/gosredirector.ea.com/8.8.8.8
#server=/blaze.ea.com/1.1.1.1
#server=/blaze.ea.com/8.8.8.8
#server=/gameservices.ea.com/1.1.1.1
#server=/gameservices.ea.com/8.8.8.8
#server=/tnt-ea.com/1.1.1.1
#server=/tnt-ea.com/8.8.8.8
#server=/np.playstation.net/1.1.1.1
#server=/np.playstation.net/8.8.8.8
#server=/np.dl.playstation.net/1.1.1.1
#server=/np.dl.playstation.net/8.8.8.8
#server=/ol.epicgames.com/1.1.1.1
#server=/ol.epicgames.com/8.8.8.8
#server=/ogs.live.on.epicgames.com/1.1.1.1
#server=/ogs.live.on.epicgames.com/8.8.8.8
#server=/edea.live.use1a.on.epicgames.com/1.1.1.1
#server=/edea.live.use1a.on.epicgames.com/8.8.8.8
#server=/core.windows.net/1.1.1.1
#server=/core.windows.net/8.8.8.8
#__END_BYPASS__

#__BEGIN_NO_AAAA__
## /etc/dnsmasq.d/no-aaaa.conf
##
## The relay and the exit are IPv4-only: nginx proxies over IPv4 and every
## address= record is an IPv4 address. But dnsmasq's address= only answers A
## queries - AAAA is forwarded upstream untouched. A dual-stack client therefore
## asks AAAA, gets the service's real IPv6 address, and connects straight to it,
## walking around the proxy entirely. Every routed domain leaks this way.
##
## The Xbox found it. catalog.gamepass.com answered A with the relay and AAAA with
## real Akamai addresses (2a02:26f0:3500:...), so the console went over IPv6, never
## touched us, and its game library never loaded. Its DNS log showed the giveaway:
##
##   query[AAAA] titlestorage.xboxlive.com  -> forwarded to 1.1.1.1 -> CNAME
##   query[A]    titlestorage.xboxlive.com  -> config is <relay>
##
## Answering NODATA for AAAA makes clients fall back cleanly to IPv4, which is the
## only path this setup can carry. It is global rather than per-domain on purpose:
## any AAAA we hand out is a route around our own proxy, whatever the name.
#filter-AAAA
#__END_NO_AAAA__

#__BEGIN_EXIT_NGINX__
## Smart DNS exit node (abroad) - nginx.conf
## Based on https://github.com/rohammosalli/smart-dns/blob/master/nginx.conf
#worker_processes  auto;
#
## Each proxied stream connection holds two descriptors, client side and
## upstream side, so the effective ceiling is half this number. The default soft
## limit is 1024, which caps the box at ~500 concurrent connections no matter
## what worker_connections says - a PS5 game download opens far more than that in
## parallel and the surplus gets reset mid-transfer.
#worker_rlimit_nofile 65535;
#load_module /usr/lib/nginx/modules/ngx_stream_module.so;
#
#events {
#    worker_connections  15000;
#    multi_accept off;
#}
#
#http {
#    access_log off;
#    resolver 1.1.1.1 ipv6=off;
#    resolver_timeout 5s;
#
#    # Console download CDNs are served over plain HTTP. Both Sony and Microsoft
#    # put theirs on Akamai's HTTP-only network:
#    #
#    #   gst.prod.dl.playstation.net -> ... -> ...edgesuite.net
#    #   assets1.xboxlive.com        -> ... -> ...edgesuite.net
#    #
#    # Those edges answer port 443 with a generic a248.e.akamai.net certificate
#    # that names no console host at all. Redirecting port 80 to https, as this
#    # file used to, therefore sent the console to a certificate it correctly
#    # refused. On the PS5 that was eight TLS alerts and a dead download; on the
#    # Xbox it was a download that never started at all, with the console
#    # re-resolving assets1.xboxlive.com dozens of times a minute.
#    #
#    # Forward these over HTTP instead of redirecting. Scoped to the console
#    # domains deliberately: the relay's port 80 is open to the internet, and a
#    # forward proxy that accepted any Host would be an open proxy.
#    server {
#        listen 80;
#        listen [::]:80;
#        server_name ~^.*\.(playstation\.(net|com)|xboxlive\.com|gamepass\.com)$;
#        allow __RELAY_IP__;
#        deny all;
#
#        location / {
#            proxy_pass http://$http_host$request_uri;
#            proxy_set_header Host $http_host;
#            proxy_http_version 1.1;
#            proxy_set_header Connection "";
#            # Game data is large and range-requested; buffering it here would
#            # add latency for no gain.
#            proxy_buffering off;
#            proxy_request_buffering off;
#            proxy_connect_timeout 10s;
#            proxy_send_timeout 10m;
#            proxy_read_timeout 10m;
#
#            # Not every host under these domains actually serves plain HTTP -
#            # packages.xboxlive.com does not, and proxying it produced a 504
#            # where it used to get a clean redirect. Fall back to the old
#            # behaviour when the upstream cannot be reached over HTTP, so this
#            # can only help and never takes something away.
#            proxy_intercept_errors on;
#            error_page 502 504 = @https_redirect;
#        }
#
#        location @https_redirect {
#            return 301 https://$http_host$request_uri;
#        }
#    }
#
#    # Everything else keeps the old behaviour.
#    server {
#        listen 80 default_server;
#        listen [::]:80 default_server;
#        server_name _;
#        return 301 https://$host$request_uri;
#    }
#}
#
#stream {
#    # A TLS client should never send a bare IP as SNI. When one does, blindly
#    # forwarding to $ssl_preread_server_name:443 sends the session straight back
#    # at the relay, which forwards it here again - an infinite loop that pins
#    # both boxes. Blackhole those, and empty SNI, into an unresolvable upstream
#    # so the session is dropped instead.
#    map $ssl_preread_server_name $target {
#        default                 $ssl_preread_server_name;
#        ""                      "";
#        ~^[0-9.]+$              "";
#        ~^\[?[0-9a-fA-F:]+\]?$  "";
#    }
#
#    # Only the Iran relay may use this proxy. Prevents open-proxy abuse.
#    server {
#        resolver 1.1.1.1 ipv6=off;
#        listen 443;
#        allow __RELAY_IP__;
#        deny all;
#        ssl_preread on;
#        proxy_connect_timeout 10s;
#        proxy_pass $target:443;
#    }
#}
#__END_EXIT_NGINX__

#__BEGIN_RELAY_NGINX__
## Smart DNS relay (inside Iran) -> exit node abroad
#worker_processes  auto;
#
## Each proxied stream connection holds two descriptors, client side and
## upstream side, so the effective ceiling is half this number. The default soft
## limit is 1024, which caps the box at ~500 concurrent connections no matter
## what worker_connections says - a PS5 game download opens far more than that in
## parallel and the surplus gets reset mid-transfer.
#worker_rlimit_nofile 65535;
#load_module __MODULE_PATH__;
#
#events {
#    worker_connections  15000;
#    multi_accept off;
#}
#
#stream {
#    server {
#        listen 443;
#        proxy_connect_timeout 10s;
#        proxy_timeout 10m;
#        proxy_pass __EXIT_IP__:443;
#    }
#
#    # Port 80 is forwarded rather than answered. It used to return a 301 to
#    # https here, which broke PlayStation downloads: their CDN is HTTP-only and
#    # serves a mismatched certificate on 443, so the console followed our
#    # redirect straight into a TLS failure. The exit decides what to do with
#    # each Host now - proxying playstation traffic, redirecting the rest.
#    server {
#        listen 80;
#        proxy_connect_timeout 10s;
#        proxy_timeout 10m;
#        proxy_pass __EXIT_IP__:80;
#    }
#}
#__END_RELAY_NGINX__

#__BEGIN_TURNSERVER__
## /etc/turnserver.conf  -  STUN only, no TURN relaying
##
## Why this exists: the relay answers *.playstation.net with its own address, and
## ps5.np.playstation.net is the PS5's STUN server. A capture showed the console
## sending eight STUN Binding Requests to the relay and getting nothing back, so
## NAT type detection failed outright - which hurts FUT matchmaking more than any
## amount of ping tuning.
##
## The console sends those Binding Requests over UDP straight to the relay, not
## through the nginx proxy, so the relay genuinely observes the console's real
## public address and can answer correctly. Serving STUN here is the honest fix;
## it keeps PSN's HTTPS traffic on the routed path so sign-in still works.
##
## stun-only is the important line. Without it coturn would also offer TURN
## relaying, and with no-auth that is an open relay for anyone on the internet.
#
#listening-port=3478
#listening-ip=__RELAY_IP__
#external-ip=__RELAY_IP__
#
## Serve STUN Binding only. No allocations, ever.
#stun-only
#no-auth
#
## Nothing here needs TLS, and offering it only widens the surface.
#no-tls
#no-dtls
#no-cli
#
## No alt-listening-port: full RFC 3489 NAT classification needs a second public
## IP for the change-IP test, and this box has one. coturn will not bind the alt
## port on a single-homed host, so setting it just looks configured without being
## so. The console therefore learns its mapping but cannot classify the cone type,
## which lands it on NAT Type 2 (moderate) - the fix here is getting an answer at
## all instead of eight timeouts, and Type 2 plays online fine.
#
#no-multicast-peers
#no-loopback-peers
#fingerprint
#simple-log
#__END_TURNSERVER__

#__BEGIN_SMARTDNS__
##!/bin/bash
## smartdns - manage the sanction-bypass domain list
## usage: smartdns add|del|list|find|test|status [domain ...]
#set -euo pipefail
#
#CONF=/etc/dnsmasq.d/smart-dns.conf
#BYPASS=/etc/dnsmasq.d/bypass.conf
#IP=__RELAY_IP__
#
#need_root() { [ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }; }
#
#case "${1:-}" in
#  add)
#    need_root; shift
#    [ $# -gt 0 ] || { echo "usage: smartdns add <domain> [domain ...]"; exit 1; }
#    for d in "$@"; do
#      d=$(echo "$d" | tr 'A-Z' 'a-z' | sed 's#^https\?://##; s#/.*##; s/^\.//')
#      if grep -qxF "address=/$d/$IP" "$CONF"; then
#        echo "already present: $d"
#      else
#        echo "address=/$d/$IP" >> "$CONF"
#        echo "added: $d"
#      fi
#    done
#    dnsmasq --test -C /etc/dnsmasq.conf && systemctl restart dnsmasq && echo "dnsmasq reloaded"
#    ;;
#  del|rm)
#    need_root; shift
#    [ $# -gt 0 ] || { echo "usage: smartdns del <domain> [domain ...]"; exit 1; }
#    for d in "$@"; do
#      d=$(echo "$d" | tr 'A-Z' 'a-z' | sed 's#^https\?://##; s#/.*##; s/^\.//')
#      if grep -qxF "address=/$d/$IP" "$CONF"; then
#        sed -i "\#^address=/$d/$IP\$#d" "$CONF"
#        echo "removed: $d"
#      else
#        echo "not found: $d"
#      fi
#    done
#    systemctl restart dnsmasq && echo "dnsmasq reloaded"
#    ;;
#  bypass)
#    # exclude a subdomain from the hijack - for services that do NOT run on 443
#    # (e.g. EA's gosredirector uses TCP 42130/42230, hijacking it kills FC 25)
#    need_root; shift
#    [ $# -gt 0 ] || { echo "usage: smartdns bypass <domain> [domain ...]"; exit 1; }
#    for d in "$@"; do
#      d=$(echo "$d" | tr 'A-Z' 'a-z' | sed 's#^https\?://##; s#/.*##; s/^\.//')
#      if grep -qxF "server=/$d/1.1.1.1" "$BYPASS"; then
#        echo "already bypassed: $d"
#      else
#        printf 'server=/%s/1.1.1.1
#server=/%s/8.8.8.8
#' "$d" "$d" >> "$BYPASS"
#        echo "bypassed (resolves to its real IP now): $d"
#      fi
#    done
#    dnsmasq --test -C /etc/dnsmasq.conf && systemctl restart dnsmasq && echo "dnsmasq reloaded"
#    ;;
#  unbypass)
#    need_root; shift
#    for d in "$@"; do
#      d=$(echo "$d" | tr 'A-Z' 'a-z' | sed 's#^https\?://##; s#/.*##; s/^\.//')
#      sed -i "\#^server=/$d/#d" "$BYPASS" && echo "un-bypassed: $d"
#    done
#    systemctl restart dnsmasq && echo "dnsmasq reloaded"
#    ;;
#  list)
#    grep '^address=' "$CONF" | sed -E 's#^address=/([^/]+)/.*#\1#' | sort
#    ;;
#  find)
#    shift; grep -i "${1:-}" "$CONF" || echo "no match"
#    ;;
#  test)
#    shift
#    for d in "$@"; do
#      got=$(dig +short +time=5 @127.0.0.1 "$d" A | tr '\n' ' ')
#      if [ "$(echo "$got" | awk '{print $1}')" = "$IP" ]; then
#        printf "%-30s ROUTED   (%s)\n" "$d" "$got"
#      else
#        printf "%-30s direct   (%s)\n" "$d" "$got"
#      fi
#    done
#    ;;
#  status|"")
#    echo "domains routed : $(grep -c '^address=' "$CONF")"
#    echo "bypassed       : $(grep -c '^server=' "$BYPASS" 2>/dev/null || echo 0) rules"
#    echo "dnsmasq        : $(systemctl is-active dnsmasq) / $(systemctl is-enabled dnsmasq)"
#    echo "nginx          : $(systemctl is-active nginx) / $(systemctl is-enabled nginx)"
#    echo "relay target   : $(grep -oE 'proxy_pass [0-9.]+:443' /etc/nginx/nginx.conf | awk '{print $2}')"
#    echo
#    echo "listeners:"
#    ss -tulnp | grep -E ':53 |:80 |:443 ' | awk '{print "  " $1, $5, $NF}'
#    ;;
#  *)
#    echo "usage: smartdns {add|del|bypass|unbypass|list|find|test|status} [domain ...]"
#    exit 1
#    ;;
#esac
#__END_SMARTDNS__

#__BEGIN_NFTABLES__
## Smart DNS relay - access control and per-client traffic accounting.
##
## This file is the structure only: the table, its chains and its empty sets.
## The contents - which addresses are allowed and how much each has used - live
## in 20-smartdns-state.conf, written by `smartdns-acl save`. Keeping them apart
## means the installer can rewrite this file on every upgrade without losing
## anybody's allowance, and means a human can read the policy without wading
## through a few hundred counters.
##
## Nothing here blocks anything. Enforcement is a separate file again,
## 30-smartdns-enforce.conf, which exists only after `smartdns-acl enforce on`.
#
#table inet smartdns {
#    # The allowlist. Managed with `smartdns-acl add|del`, and from stage 2
#    # onwards by the panel's sync service. Each element carries the owner's
#    # name as an nftables comment, so the kernel's own copy is readable
#    # without consulting a database.
#    set allowed {
#        type ipv4_addr
#    }
#
#    # Per-client byte counters, one set per direction, both keyed on the
#    # client address.
#    #
#    # The update rules below match `ip saddr @allowed` first, so these sets
#    # only ever see addresses that are already registered. That is deliberate:
#    # a dynamic set that accepted every source would fill with the port scans
#    # this box gets around the clock, and the size cap would eventually start
#    # dropping real users' entries. Bounded by the customer count instead.
#    set up {
#        type ipv4_addr
#        flags dynamic
#        counter
#    }
#    set down {
#        type ipv4_addr
#        flags dynamic
#        counter
#    }
#
#    # Which shaping class each client belongs to, as a packet mark. Empty
#    # until somebody is given a speed limit; managed by `smartdns-shape`.
#    #
#    # The mark is the customer's account number, and tc has one class per
#    # mark. Marking here rather than matching addresses in tc keeps the
#    # address list in one place - this table - and makes the tc side a fixed
#    # set of rules that only changes when a customer's speed does.
#    map speed {
#        type ipv4_addr : mark
#    }
#
#    # Marks what we are about to send a client, so the queueing discipline on
#    # the way out can put it in that customer's class.
#    #
#    # The output hook, not postrouting: this box is a proxy, not a router, so
#    # every packet a customer receives is generated locally by nginx or
#    # dnsmasq. An address missing from the map is a lookup miss, which ends
#    # this rule and leaves the packet unmarked and unshaped.
#    chain shape {
#        type filter hook output priority mangle ; policy accept ;
#        meta mark set ip daddr map @speed
#    }
#
#    # Enforcement lands here. Empty unless `smartdns-acl enforce on` has been
#    # run. It sits at priority -10, ahead of the counting chains, so blocked
#    # packets are not billed to anyone.
#    chain gate {
#        type filter hook input priority -10 ; policy accept ;
#    }
#
#    # What the client sends us: DNS queries, and the TLS/HTTP requests it
#    # opens against the relay. Filtering on the service ports keeps our own
#    # SSH sessions and the box's housekeeping out of the customer's bill.
#    chain count_in {
#        type filter hook input priority 10 ; policy accept ;
#        ip saddr @allowed udp dport 53 update @up { ip saddr counter }
#        ip saddr @allowed tcp dport { 53, 80, 443 } update @up { ip saddr counter }
#    }
#
#    # What we send back. nginx talks to the exit node as a local process, from
#    # this same hook, but the exit's address is not in @allowed so that traffic
#    # is not counted - otherwise every byte would be billed twice.
#    chain count_out {
#        type filter hook output priority 10 ; policy accept ;
#        ip daddr @allowed udp sport 53 update @down { ip daddr counter }
#        ip daddr @allowed tcp sport { 53, 80, 443 } update @down { ip daddr counter }
#    }
#
#    # Amplification defence, unchanged. An open resolver is worth roughly its
#    # bandwidth to whoever finds it, and this box is easy to find.
#    chain input {
#        type filter hook input priority 0 ; policy accept ;
#        udp dport 53 meter dnsflood { ip saddr limit rate over 40/second burst 80 packets } drop
#    }
#}
#__END_NFTABLES__

#__BEGIN_SMARTDNS_ACL__
##!/bin/bash
## smartdns-acl - who may use this relay, and how much they have used
##
## usage: smartdns-acl add <ip> [name]     register an address
##        smartdns-acl del <ip>            unregister it
##        smartdns-acl list                everyone, with usage
##        smartdns-acl usage <ip>          one address
##        smartdns-acl reset <ip>|--all    zero the counters
##        smartdns-acl enforce on|off|status
##          --yes          do not ask for confirmation
##          --allow-empty  close it with nobody registered (the installer)
##        smartdns-acl save                persist to disk now
##
## Add --json to list or usage for output meant for the panel rather than a
## person. The panel will call this rather than touching nftables itself, so
## that there is one place where the rules about what is legal live.
#set -uo pipefail
#export PATH="$PATH:/usr/sbin:/sbin"
#
#TABLE="inet smartdns"
## Field separator for dump(). Deliberately not a tab: bash counts tabs as IFS
## whitespace, so a row whose name is empty collapses two separators into one
## and every column after it shifts left by one. That turned an unnamed address
## into a name of "0" and a byte count of "", which is how it was found.
#SEP=$'\x1f'
#STATE=/etc/nftables.d/20-smartdns-state.conf
#ENFORCE=/etc/nftables.d/30-smartdns-enforce.conf
## "Close this relay as soon as there is somebody to allow." The installer no
## longer writes it - it closes the relay itself - but relays installed before
## that still carry one, and the sync agent still acts on it, so `enforce off`
## has to keep clearing it. Opening a relay by hand and having a background
## agent shut it again half a minute later would be its own bug.
#AUTO=/etc/smart-dns/auto-enforce
#
#R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'
#[ -t 1 ] || { R=; G=; Y=; N=; }
#
#die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
#root() { [ "$(id -u)" = 0 ] || die "run as root"; }
#
#have_table() { nft list table $TABLE >/dev/null 2>&1; }
#
#valid_ip() {
#    local ip="${1:-}" o n=0
#    case "$ip" in ""|*[!0-9.]*|*..*|.*|*.) return 1 ;; esac
#    for o in ${ip//./ }; do
#        [ "$o" -ge 0 ] 2>/dev/null && [ "$o" -le 255 ] || return 1
#        n=$((n + 1))
#    done
#    [ "$n" = 4 ]
#}
#
## Everything that reads the ruleset goes through nft's JSON output and python,
## never through awk on the human-readable format. That format wraps long
## element lists at whatever width it feels like - which is exactly the sort of
## thing that works on a test box with three users and quietly mangles the
## fiftieth.
#dump() {
#    nft -j list table $TABLE 2>/dev/null | python3 -c '
#import json, sys
#
#def elements(doc, name):
#    for item in doc.get("nftables", []):
#        s = item.get("set")
#        if s and s.get("name") == name:
#            return s.get("elem", []) or []
#    return []
#
#def walk(elems):
#    # An element is a bare value until it carries a comment or a counter, at
#    # which point nft wraps it in {"elem": {...}}. Flatten both shapes.
#    out = {}
#    for e in elems:
#        val, comment, byts = e, "", 0
#        if isinstance(e, dict) and "elem" in e:
#            inner = e["elem"]
#            val = inner.get("val", "")
#            comment = inner.get("comment") or ""
#            byts = (inner.get("counter") or {}).get("bytes", 0)
#        if isinstance(val, dict):
#            val = val.get("prefix", {}).get("addr", "")
#        out[str(val)] = (comment, byts)
#    return out
#
#doc = json.load(sys.stdin)
#allowed = walk(elements(doc, "allowed"))
#up      = walk(elements(doc, "up"))
#down    = walk(elements(doc, "down"))
#for ip in sorted(allowed, key=lambda a: [int(p) for p in a.split(".")]):
#    print("%s\x1f%s\x1f%d\x1f%d" % (ip, allowed[ip][0],
#                                    up.get(ip, ("", 0))[1], down.get(ip, ("", 0))[1]))
#'
#}
#
#human() {
#    python3 -c '
#import sys
#n = float(sys.argv[1])
#for unit in ("B", "KB", "MB", "GB", "TB"):
#    if n < 1024 or unit == "TB":
#        print(("%d %s" if unit == "B" else "%.2f %s") % (n, unit))
#        break
#    n /= 1024
#' "$1"
#}
#
#save() {
#    root; have_table || die "the smartdns table is not loaded"
#    mkdir -p /etc/nftables.d
#    local tmp ip name u d
#    tmp="$(mktemp)"
#    {
#        echo "# Written by smartdns-acl. Do not edit by hand - it is"
#        echo "# regenerated from the running ruleset every few minutes."
#        echo "# Registered addresses and their usage as of $(date -Is)."
#        echo
#        while IFS="$SEP" read -r ip name u d; do
#            [ -n "$ip" ] || continue
#            if [ -n "$name" ]; then
#                printf 'add element inet smartdns allowed { %s comment "%s" }\n' "$ip" "$name"
#            else
#                printf 'add element inet smartdns allowed { %s }\n' "$ip"
#            fi
#            # Packet counts are not restored. Only bytes are billed, and
#            # carrying a packet count across a reboot buys nothing.
#            printf 'add element inet smartdns up { %s counter packets 0 bytes %s }\n' "$ip" "$u"
#            printf 'add element inet smartdns down { %s counter packets 0 bytes %s }\n' "$ip" "$d"
#        done < <(dump)
#    } > "$tmp"
#    # The sets already exist, so -c on a file of `add element` really does
#    # validate what we are about to leave behind for the next boot.
#    if nft -c -f "$tmp" >/dev/null 2>&1; then
#        mv "$tmp" "$STATE"; chmod 644 "$STATE"
#    else
#        rm -f "$tmp"; die "the generated state file does not parse - not saving"
#    fi
#}
#
#registered() { dump | cut -d"$SEP" -f1 | grep -qxF "$1"; }
#
#case "${1:-}" in
#
#add)
#    root; shift
#    ip="${1:-}"; name="${2:-}"
#    valid_ip "$ip" || die "not an IPv4 address: ${ip:-<missing>}"
#    have_table || die "the smartdns table is not loaded; run the installer"
#    case "$name" in *'"'*|*'\'*) die "a name cannot contain a quote or a backslash" ;; esac
#    registered "$ip" && die "$ip is already registered"
#    if [ -n "$name" ]; then
#        nft add element $TABLE allowed "{ $ip comment \"$name\" }" || die "nft refused the address"
#    else
#        nft add element $TABLE allowed "{ $ip }" || die "nft refused the address"
#    fi
#    # Seed both counters so the address appears in `list` before it has sent
#    # a single packet. Without this a freshly added user looks like a failure.
#    nft add element $TABLE up   "{ $ip counter packets 0 bytes 0 }" 2>/dev/null
#    nft add element $TABLE down "{ $ip counter packets 0 bytes 0 }" 2>/dev/null
#    save
#    printf '%sadded%s %s%s\n' "$G" "$N" "$ip" "${name:+  ($name)}"
#    ;;
#
#del|rm|remove)
#    root; shift
#    ip="${1:-}"
#    valid_ip "$ip" || die "not an IPv4 address: ${ip:-<missing>}"
#    have_table || die "the smartdns table is not loaded"
#    registered "$ip" || die "$ip is not registered"
#    nft delete element $TABLE allowed "{ $ip }" || die "nft refused the removal"
#    nft delete element $TABLE up   "{ $ip }" 2>/dev/null
#    nft delete element $TABLE down "{ $ip }" 2>/dev/null
#    save
#    printf '%sremoved%s %s\n' "$G" "$N" "$ip"
#    ;;
#
#list|ls)
#    have_table || die "the smartdns table is not loaded"
#    if [ "${2:-}" = --json ]; then
#        dump | python3 -c '
#import json, sys
#rows = []
#for line in sys.stdin:
#    if not line.strip():
#        continue
#    ip, name, u, d = line.rstrip("\n").split("\x1f")
#    rows.append({"ip": ip, "name": name, "up": int(u), "down": int(d),
#                 "total": int(u) + int(d)})
#print(json.dumps(rows))
#'
#        exit 0
#    fi
#    rows="$(dump)"
#    if [ -z "$rows" ]; then
#        echo "no addresses registered yet - add one with: smartdns-acl add <ip> [name]"
#        exit 0
#    fi
#    printf '%-16s %-16s %12s %12s %12s\n' ADDRESS NAME UP DOWN TOTAL
#    while IFS="$SEP" read -r ip name u d; do
#        printf '%-16s %-16s %12s %12s %12s\n' \
#            "$ip" "${name:--}" "$(human "$u")" "$(human "$d")" "$(human $((u + d)))"
#    done <<< "$rows"
#    ;;
#
#usage)
#    have_table || die "the smartdns table is not loaded"
#    ip="${2:-}"
#    valid_ip "$ip" || die "not an IPv4 address: ${ip:-<missing>}"
#    registered "$ip" || die "$ip is not registered"
#    # Field-exact, not a substring: grepping for "1.2.3.4" would also find
#    # the row belonging to 11.2.3.4.
#    IFS="$SEP" read -r _ name u d < <(dump | awk -F"$SEP" -v a="$ip" '$1 == a')
#    if [ "${3:-}" = --json ]; then
#        printf '{"ip":"%s","name":"%s","up":%s,"down":%s,"total":%s}\n' \
#            "$ip" "$name" "$u" "$d" "$((u + d))"
#    else
#        printf '%s%s\n' "$ip" "${name:+  ($name)}"
#        printf '    up    %s\n' "$(human "$u")"
#        printf '    down  %s\n' "$(human "$d")"
#        printf '    total %s\n' "$(human $((u + d)))"
#    fi
#    ;;
#
#reset)
#    root; shift
#    have_table || die "the smartdns table is not loaded"
#    if [ "${1:-}" = --all ]; then
#        targets="$(dump | cut -d"$SEP" -f1)"
#    else
#        valid_ip "${1:-}" || die "usage: smartdns-acl reset <ip>|--all"
#        registered "$1" || die "$1 is not registered"
#        targets="$1"
#    fi
#    for ip in $targets; do
#        for s in up down; do
#            nft delete element $TABLE "$s" "{ $ip }" 2>/dev/null
#            nft add element $TABLE "$s" "{ $ip counter packets 0 bytes 0 }" 2>/dev/null
#        done
#        printf '%sreset%s %s\n' "$G" "$N" "$ip"
#    done
#    save
#    ;;
#
#enforce)
#    have_table || die "the smartdns table is not loaded"
#    case "${2:-status}" in
#    on)
#        root
#        count="$(dump | grep -c . )"
#        yes=no; empty=no
#        for flag in "$@"; do
#            case "$flag" in
#                --yes) yes=yes ;;
#                --allow-empty) empty=yes ;;
#            esac
#        done
#        # Switching this on with an empty allowlist cuts off every user of the
#        # service at once. For somebody typing it at a terminal that is almost
#        # always a mistake, and one that feels irreversible from the far end of
#        # a broken connection - so it refuses.
#        #
#        # The installer passes --allow-empty, because there it is not a
#        # mistake: a relay being installed has no users to cut off, and the
#        # list being empty is exactly why it has to be closed. Left open, it is
#        # a relay anybody who learns its address can use for free.
#        if [ "$count" -eq 0 ] && [ "$empty" != yes ]; then
#            die "the allowlist is empty - everyone would be cut off.
#    Register at least your own address first:  smartdns-acl add <your ip> me"
#        fi
#        if [ "$yes" != yes ] && [ -t 0 ]; then
#            printf '%s%s address(es) registered.%s Everyone else loses DNS, HTTP\n' "$Y" "$count" "$N"
#            printf 'and HTTPS through this relay immediately. SSH is not affected.\n'
#            printf 'Continue? [y/N] '
#            read -r ans
#            case "$ans" in y|Y|yes) ;; *) echo "cancelled"; exit 1 ;; esac
#        fi
#        mkdir -p /etc/nftables.d
#        cat > "$ENFORCE" <<'RULES'
## Access control, switched on by `smartdns-acl enforce on`.
## Delete this file, or run `smartdns-acl enforce off`, to open the relay again.
## There is deliberately no rule for SSH: getting the allowlist wrong must never
## cost you access to the machine.
#
## The machine talks to its own resolver: epic-pin probes it every ten minutes,
## and the installer's checks query it directly. Neither is a customer and
## neither is in the allowlist, so without this line switching enforcement on
## would quietly break both.
#add rule inet smartdns gate iif "lo" accept
#
#add rule inet smartdns gate ip saddr != @allowed udp dport 53 drop
#add rule inet smartdns gate ip saddr != @allowed tcp dport { 53, 80, 443 } drop
#RULES
#        nft flush chain $TABLE gate
#        nft -f "$ENFORCE" || { rm -f "$ENFORCE"; die "nft refused the rules; nothing changed"; }
#        if [ "$count" -eq 0 ]; then
#            printf '%senforcing%s - nobody may use this relay yet.\n' "$G" "$N"
#            printf 'Addresses are let in as customers register them.\n'
#        else
#            printf '%senforcing%s - %s address(es) may use this relay\n' \
#                   "$G" "$N" "$count"
#        fi
#        ;;
#    off)
#        root
#        nft flush chain $TABLE gate
#        rm -f "$ENFORCE"
#        # Also cancel the installer's standing instruction to close the relay
#        # once somebody registers. Opening it by hand and having a background
#        # agent shut it again half a minute later would be its own bug.
#        if [ -f "$AUTO" ]; then
#            rm -f "$AUTO"
#            printf 'automatic enforcement cancelled too\n'
#        fi
#        printf '%sopen%s - nothing is being blocked\n' "$Y" "$N"
#        ;;
#    status)
#        if nft list chain $TABLE gate 2>/dev/null | grep -q drop; then
#            printf 'enforcing - %s address(es) allowed\n' "$(dump | grep -c .)"
#        else
#            printf 'open - counting only, nothing is blocked\n'
#        fi
#        ;;
#    *) die "usage: smartdns-acl enforce on|off|status" ;;
#    esac
#    ;;
#
#save)
#    save; echo "saved to $STATE"
#    ;;
#
#*)
#    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
#    exit 1
#    ;;
#esac
#__END_SMARTDNS_ACL__

#__BEGIN_SMARTDNS_SHAPE__
##!/usr/bin/env python3
#"""smartdns-shape - per-customer download speed limits on the relay.
#
#usage: smartdns-shape apply      read the wanted state as JSON on stdin
#       smartdns-shape list       show what is in force
#       smartdns-shape off        remove all shaping, leaving traffic alone
#
#The wanted state is a list of {"ip", "mark", "kbps"}. kbps is kilobits per
#second; a customer with no limit is simply absent from it.
#
#Why this shape and not another
#------------------------------
#Only the download direction is shaped - what the relay sends to the customer.
#That is the direction a customer notices, and on this box it is also the easy
#one: the relay is a proxy rather than a router, so every packet a customer
#receives is generated locally and leaves through one interface, where a
#queueing discipline can see it. Shaping the upload direction would mean
#policing on ingress through an ifb device, which drops rather than queues and
#buys very little for a service whose traffic is overwhelmingly inbound.
#
#htb, not a rate limit in nftables. nftables can drop above a rate, and drops
#are not shaping: TCP reacts to loss by collapsing its window, so a customer
#capped that way gets a connection that stalls and lurches rather than one that
#runs steadily a little slower. htb queues instead, and hands each class to
#fq_codel so a customer's own bulk download cannot drown out their own game.
#
#The address list stays in nftables, not here. nftables marks each packet with
#the customer's account number and tc matches the mark, so the tc side is a
#fixed set of rules that changes only when somebody's speed changes - and the
#question "which addresses does this box know about" keeps exactly one answer.
#"""
#import json
#import re
#import subprocess
#import sys
#
## Root class: the ceiling every customer class hangs under. Deliberately far
## above any real link speed, because it is not a limit - it is the parent htb
## needs, and setting it near the true line rate would cap customers who have
## no limit of their own.
#ROOT_RATE = "10gbit"
#
## Where unmarked traffic goes: everything that is not a shaped customer,
## including our own ssh session and the sync agent. Unshaped on purpose.
#DEFAULT_MINOR = 0xFFFF
#
## Customer classes live above this, never at it. The mark identifies the
## customer everywhere else - in the nftables map and as the fw filter's handle
## - but it cannot be the class minor as well, because minor 1 is the root
## class every customer class hangs under and 1: is the root qdisc's own
## handle. The first customer ever shaped has mark 1, so both collided at once:
## `tc qdisc replace ... parent 1:1 handle 1: fq_codel` was refused every
## thirty seconds, and the class that did get created replaced the root class,
## quietly capping the whole relay at that one customer's speed.
#CLASS_BASE = 0x100
#
## Marks are account numbers, and this one is taken by the default class.
#MAX_MARK = DEFAULT_MINOR - CLASS_BASE - 1
#
#TABLE = "inet smartdns"
#MAP = "speed"
#
#R = "\033[31m"; G = "\033[32m"; Y = "\033[33m"; N = "\033[0m"
#if not sys.stdout.isatty():
#    R = G = Y = N = ""
#
#
#def die(msg):
#    sys.stderr.write("%serror:%s %s\n" % (R, N, msg))
#    raise SystemExit(1)
#
#
#def run(*args, **kw):
#    return subprocess.run(list(args), capture_output=True, text=True,
#                          timeout=kw.get("timeout", 30))
#
#
#def tc(*args, check=True):
#    r = run("tc", *args)
#    if check and r.returncode != 0:
#        die("tc %s: %s" % (" ".join(args), r.stderr.strip()))
#    return r
#
#
#def nft(*args, check=True):
#    r = run("nft", *args)
#    if check and r.returncode != 0:
#        die("nft %s: %s" % (" ".join(args), r.stderr.strip()))
#    return r
#
#
#def wan():
#    """The interface customer traffic leaves by - the default route's."""
#    r = run("ip", "-o", "route", "get", "1.1.1.1")
#    if r.returncode != 0:
#        die("cannot work out which interface to shape: %s" % r.stderr.strip())
#    fields = r.stdout.split()
#    if "dev" not in fields:
#        die("no device in: %s" % r.stdout.strip())
#    return fields[fields.index("dev") + 1]
#
#
## ------------------------------------------------------------------- state
#RATE_RE = re.compile(r"\brate\s+(\d+(?:\.\d+)?)([KMGT]?)bit", re.I)
#CLASS_RE = re.compile(r"^class\s+htb\s+1:([0-9a-f]+)\b", re.I)
#SCALE = {"": 0.001, "K": 1, "M": 1000, "G": 1000000, "T": 1000000000}
#
#
#def current_classes(dev):
#    """{minor: rate in kbit} for the customer classes that exist now.
#
#    Two output formats, because `tc -j` is not honoured everywhere: iproute2
#    6.1 emits JSON for `qdisc show` but silently prints the plain text format
#    for `class show`, which json.loads then chokes on. Rather than pin a
#    version, read whichever came back - the text format has been stable for
#    twenty years and is trivial to parse.
#    """
#    r = tc("-j", "class", "show", "dev", dev, check=False)
#    if r.returncode != 0 or not r.stdout.strip():
#        return {}
#    out = {}
#    text = r.stdout.lstrip()
#    if text.startswith("["):
#        for c in json.loads(text):
#            handle = c.get("handle", "")
#            major, _, minor = handle.partition(":")
#            if major != "1" or not minor:
#                continue
#            m = int(minor, 16)
#            if m > CLASS_BASE and m != DEFAULT_MINOR:
#                # Keyed by mark, so the caller compares like with like.
#                out[m - CLASS_BASE] = int(c.get("rate", 0)) // 1000
#        return out
#    for line in text.splitlines():
#        hit = CLASS_RE.match(line.strip())
#        if not hit:
#            continue
#        m = int(hit.group(1), 16)
#        if m <= CLASS_BASE or m == DEFAULT_MINOR:
#            continue
#        rate = RATE_RE.search(line)
#        out[m - CLASS_BASE] = (int(float(rate.group(1)) * SCALE[rate.group(2).upper()])
#                               if rate else 0)
#    return out
#
#
#def ensure_root(dev):
#    """Put the htb root in place if it is not there already.
#
#    Replacing it when it already exists would throw away every customer class
#    on a run that was meant to change one of them, so this checks first.
#    """
#    r = tc("-j", "qdisc", "show", "dev", dev, check=False)
#    have_htb = False
#    if r.returncode == 0 and r.stdout.strip():
#        have_htb = any(q.get("kind") == "htb" and q.get("handle") == "1:"
#                       for q in json.loads(r.stdout))
#    if have_htb:
#        return False
#    tc("qdisc", "replace", "dev", dev, "root", "handle", "1:",
#       "htb", "default", format(DEFAULT_MINOR, "x"))
#    tc("class", "replace", "dev", dev, "parent", "1:", "classid", "1:1",
#       "htb", "rate", ROOT_RATE, "ceil", ROOT_RATE)
#    tc("class", "replace", "dev", dev, "parent", "1:1",
#       "classid", "1:%x" % DEFAULT_MINOR,
#       "htb", "rate", ROOT_RATE, "ceil", ROOT_RATE)
#    tc("qdisc", "replace", "dev", dev, "parent", "1:%x" % DEFAULT_MINOR,
#       "handle", "%x:" % DEFAULT_MINOR, "fq_codel")
#    return True
#
#
#def minor_for(mark):
#    """The class minor a mark gets. Never 1, never DEFAULT_MINOR."""
#    return CLASS_BASE + mark
#
#
#def add_class(dev, mark, kbps):
#    rate = "%dkbit" % kbps
#    minor = minor_for(mark)
#    tc("class", "replace", "dev", dev, "parent", "1:1",
#       "classid", "1:%x" % minor, "htb", "rate", rate, "ceil", rate,
#       # A burst of roughly a tenth of a second, so a limit reads as a steady
#       # speed rather than as a stutter, without letting a customer bank
#       # seconds of idle time into a spike the operator pays for.
#       "burst", "%dkbit" % max(15, kbps // 10))
#    tc("qdisc", "replace", "dev", dev, "parent", "1:%x" % minor,
#       "handle", "%x:" % minor, "fq_codel")
#    # The filter is keyed on the mark, so re-adding an identical one would
#    # stack duplicates. Delete first, ignore the failure when there is none.
#    tc("filter", "del", "dev", dev, "parent", "1:", "protocol", "ip",
#       "prio", "1", "handle", str(mark), "fw", check=False)
#    tc("filter", "add", "dev", dev, "parent", "1:", "protocol", "ip",
#       "prio", "1", "handle", str(mark), "fw", "flowid", "1:%x" % minor)
#
#
#def drop_class(dev, mark):
#    minor = minor_for(mark)
#    tc("filter", "del", "dev", dev, "parent", "1:", "protocol", "ip",
#       "prio", "1", "handle", str(mark), "fw", check=False)
#    tc("qdisc", "del", "dev", dev, "parent", "1:%x" % minor, check=False)
#    tc("class", "del", "dev", dev, "parent", "1:1",
#       "classid", "1:%x" % minor, check=False)
#
#
#def set_map(wanted):
#    """Replace the address-to-mark map in one step.
#
#    Flush and refill rather than working out the difference: the map is at
#    most a few hundred entries, and a customer must never be briefly missing
#    from it because their speed changed.
#    """
#    nft("flush", "map", *TABLE.split(), MAP)
#    if not wanted:
#        return
#    elements = ", ".join("%s : %d" % (w["ip"], w["mark"]) for w in wanted)
#    nft("add", "element", *TABLE.split(), MAP, "{ %s }" % elements)
#
#
## ------------------------------------------------------------------ verbs
#def apply_wanted(wanted):
#    dev = wan()
#    seen = set()
#    clean = []
#    for w in wanted:
#        try:
#            mark, kbps = int(w["mark"]), int(w["kbps"])
#        except (KeyError, TypeError, ValueError):
#            die("bad entry: %r" % (w,))
#        if not 1 <= mark <= MAX_MARK:
#            die("mark %d is outside 1..%d" % (mark, MAX_MARK))
#        if mark in seen:
#            die("mark %d appears twice" % mark)
#        if kbps <= 0:
#            continue                     # no limit means no class
#        seen.add(mark)
#        clean.append({"ip": w["ip"], "mark": mark, "kbps": kbps})
#
#    if not clean:
#        # Nobody is limited, so leave the interface as the kernel set it up.
#        # htb replaces the multi-queue root, which costs a little throughput on
#        # a busy relay - not much, but not worth paying to shape nobody.
#        return teardown(dev, "no speed limits set")
#
#    built = ensure_root(dev)
#    have = current_classes(dev)
#    want = {w["mark"]: w["kbps"] for w in clean}
#
#    added = changed = removed = 0
#    for mark, kbps in sorted(want.items()):
#        if mark not in have:
#            added += 1
#        elif have[mark] != kbps:
#            changed += 1
#        else:
#            continue
#        add_class(dev, mark, kbps)
#    for mark in sorted(set(have) - set(want)):
#        drop_class(dev, mark)
#        removed += 1
#
#    set_map(clean)
#    if built or added or changed or removed:
#        print("shaping on %s: %d limited (+%d ~%d -%d)%s"
#              % (dev, len(clean), added, changed, removed,
#                 " [root created]" if built else ""))
#    return 0
#
#
#def show():
#    dev = wan()
#    have = current_classes(dev)
#    r = nft("-j", "list", "map", *TABLE.split(), MAP, check=False)
#    by_mark = {}
#    if r.returncode == 0 and r.stdout.strip():
#        for item in json.loads(r.stdout).get("nftables", []):
#            for e in (item.get("map", {}).get("elem") or []):
#                if isinstance(e, list) and len(e) == 2:
#                    by_mark[int(e[1])] = e[0]
#    if not have:
#        print("no speed limits in force on %s" % dev)
#        return 0
#    print("%-16s %-8s %s" % ("ADDRESS", "MARK", "LIMIT"))
#    for mark in sorted(have):
#        kbps = have[mark]
#        speed = ("%.1f Mbit/s" % (kbps / 1000.0)) if kbps >= 1000 \
#            else "%d kbit/s" % kbps
#        print("%-16s %-8d %s" % (by_mark.get(mark, "?"), mark, speed))
#    return 0
#
#
#def teardown(dev, why):
#    """Put the interface back the way the kernel had it.
#
#    Only says anything when there was something to remove, so the sync agent
#    calling this on a relay that has never shaped anybody stays quiet.
#    """
#    had = current_classes(dev)
#    for mark in had:
#        drop_class(dev, mark)
#    if had:
#        tc("qdisc", "del", "dev", dev, "root", check=False)
#    nft("flush", "map", *TABLE.split(), MAP, check=False)
#    if had:
#        print("%s on %s: %d class(es) removed" % (why, dev, len(had)))
#    return 0
#
#
#def off():
#    dev = wan()
#    teardown(dev, "shaping removed")
#    # Unconditionally here, unlike the reconciling path: `off` is a person
#    # asking for the root to go, whether or not any class is left.
#    tc("qdisc", "del", "dev", dev, "root", check=False)
#    print("shaping off on %s" % dev)
#    return 0
#
#
#def main():
#    verb = sys.argv[1] if len(sys.argv) > 1 else ""
#    if verb == "apply":
#        try:
#            wanted = json.loads(sys.stdin.read() or "[]")
#        except ValueError as e:
#            die("stdin is not valid json: %s" % e)
#        if not isinstance(wanted, list):
#            die("expected a list of {ip, mark, kbps}")
#        return apply_wanted(wanted)
#    if verb == "list":
#        return show()
#    if verb == "off":
#        return off()
#    sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
#    return 1
#
#
#if __name__ == "__main__":
#    raise SystemExit(main())
#__END_SMARTDNS_SHAPE__

#__BEGIN_ACL_SAVE_SERVICE__
#[Unit]
#Description=Persist smart DNS allowlist and traffic counters
#After=nftables.service
#
#[Service]
## A plain oneshot on purpose. With RemainAfterExit=yes the unit would stay
## active after its first run and every later trigger from the timer would be
## silently skipped - the counters would then be written exactly once, at boot.
#Type=oneshot
#ExecStart=/usr/local/bin/smartdns-acl save
#__END_ACL_SAVE_SERVICE__

#__BEGIN_ACL_SAVE_TIMER__
#[Unit]
#Description=Persist smart DNS counters every few minutes
#
#[Timer]
## Counters live in the kernel. An unclean shutdown loses whatever has not
## been written out, so the window is kept short enough that nobody can burn
## a meaningful amount of quota inside it.
#OnBootSec=3min
#OnUnitActiveSec=5min
#
#[Install]
#WantedBy=timers.target
#__END_ACL_SAVE_TIMER__

#__BEGIN_PANEL__
##!/usr/bin/env python3
#"""smartdns-panel - the database behind the relays, and the API they sync to.
#
#This runs on the exit node, not on the relay. The relay connects out to this
#API every half minute to hand over per-address usage and collect the list of
#addresses it should allow, which resolver each is on, and what speed each is
#capped at. The relay always initiates: it is the machine in the harder network
#position, and this way it needs no new inbound port.
#
#One database serves every relay. That is what makes a customer's allowance
#mean one thing across the whole service rather than one thing per machine.
#
#There was a Telegram bot in this process. It is gone: almost every account was
#opened on the web panel and had no Telegram behind it, so the bot's commands
#had all grown web equivalents and its messages were reaching a shrinking
#minority. What it did for customers - registering an address, seeing an
#account, being warned before the allowance runs out - the panel on each relay
#now does for everybody.
#
#Only the standard library is used, so the installer stays a single file with
#no pip step.
#"""
#
#import base64
#import hashlib
#import hmac
#import html
#import http.server
#import json
#import os
#import re
#import secrets
#import signal
#import shutil
#import sqlite3
#import ssl
#import sys
#import threading
#import time
#import unicodedata
#import urllib.error
#import urllib.parse
#import urllib.request
#from datetime import datetime, timedelta, timezone
#
#CONFIG = "/etc/smart-dns/panel.env"
#DB = "/var/lib/smart-dns/panel.db"
#CERT = "/etc/smart-dns/sync.crt"
#KEY = "/etc/smart-dns/sync.key"
#API_PORT = 8443
#
#SCHEMA = """
#CREATE TABLE IF NOT EXISTS users (
#    id             INTEGER PRIMARY KEY,
#    -- Null for an account opened on the web panel. Telegram is one way in, not
#    -- the only one. UNIQUE still holds where it matters: sqlite allows many
#    -- nulls in a unique column, which is the behaviour wanted here.
#    telegram_id    INTEGER UNIQUE,
#    -- How a web account signs in. Nothing verifies it - there is no SMS
#    -- gateway - so it names an account and lets a card receipt be matched to
#    -- one. It is not evidence about who holds the line.
#    phone          TEXT UNIQUE,
#    password_hash  TEXT,
#    password_salt  TEXT,
#    username       TEXT,
#    first_name     TEXT,
#    created_at     TEXT NOT NULL,
#    status         TEXT NOT NULL DEFAULT 'active',
#    -- 0 means unlimited. Quota is counted in bytes, on the wire, both
#    -- directions, which is what the kernel counters actually measure.
#    quota_bytes    INTEGER NOT NULL DEFAULT 0,
#    quota_mode     TEXT NOT NULL DEFAULT 'monthly',
#    quota_reset_at TEXT,
#    used_bytes     INTEGER NOT NULL DEFAULT 0,
#    max_ips        INTEGER NOT NULL DEFAULT 1,
#    wallet         INTEGER NOT NULL DEFAULT 0,
#    -- Download limit in kilobits per second, 0 for no limit. The relay turns
#    -- this into one htb class per customer; the number lives here because the
#    -- relay must be able to be rebuilt from nothing but a sync.
#    speed_kbps     INTEGER NOT NULL DEFAULT 0,
#    -- When this account stops working regardless of how much is left. Set for
#    -- the trial; null for a paid account, which ends when its quota does.
#    expires_at     TEXT
#);
#
#-- One row per registered address. UNIQUE(ip) is deliberate: without it a
#-- second account could register an address someone else is already paying
#-- for and ride along free.
#CREATE TABLE IF NOT EXISTS ips (
#    id           INTEGER PRIMARY KEY,
#    user_id      INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
#    ip           TEXT NOT NULL UNIQUE,
#    added_at     TEXT NOT NULL,
#    -- The last raw counter this address reported. Usage is the growth of that
#    -- number, so a user who changes address keeps the total they had built up.
#    last_counter INTEGER NOT NULL DEFAULT 0
#);
#
#-- A customer's claim that they paid, and the photograph of the slip.
#--
#-- The image is a blob rather than a file beside the database, so that one
#-- backup is the whole story and a restore brings the pending ones back with
#-- everything else. It does not grow without bound: the image is dropped the
#-- moment the operator decides, leaving the row as the record.
#CREATE TABLE IF NOT EXISTS transactions (
#    id           INTEGER PRIMARY KEY,
#    user_id      INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
#    amount       INTEGER NOT NULL,
#    kind         TEXT NOT NULL,
#    receipt      TEXT,
#    receipt_blob BLOB,
#    receipt_type TEXT,
#    note         TEXT,
#    status       TEXT NOT NULL DEFAULT 'pending',
#    created_at   TEXT NOT NULL,
#    decided_at   TEXT
#);
#
#-- The operator's own browser sessions for the admin panel. In the database
#-- rather than in that process's memory, because it restarts on every upgrade
#-- and whenever its port or path changes - and being signed out by a restart
#-- left the operator staring at the same bare 404 a stranger gets.
#CREATE TABLE IF NOT EXISTS admin_sessions (
#    token      TEXT PRIMARY KEY,
#    expires_at TEXT NOT NULL
#);
#
#CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);
#CREATE INDEX IF NOT EXISTS ips_user ON ips(user_id);
#
#-- A template is a named set of service groups that route through the relay.
#-- Customers are assigned one; they do not get an arbitrary per-customer
#-- combination, because each distinct combination costs a dnsmasq instance on
#-- every relay and the count has to stay small enough to run. Templates make
#-- that limit a product decision - how many plans do you sell - rather than an
#-- accident waiting to happen.
#CREATE TABLE IF NOT EXISTS templates (
#    id         INTEGER PRIMARY KEY,
#    name       TEXT UNIQUE NOT NULL,
#    is_default INTEGER NOT NULL DEFAULT 0,
#    created_at TEXT NOT NULL
#);
#
#-- One row per group the template routes. A group absent from here is bypassed
#-- for that template: resolved to its real address so the client reaches it
#-- directly, costing the operator nothing and the customer some speed.
#CREATE TABLE IF NOT EXISTS template_services (
#    template_id INTEGER NOT NULL REFERENCES templates(id) ON DELETE CASCADE,
#    service_key TEXT NOT NULL,
#    group_key   TEXT NOT NULL,
#    PRIMARY KEY (template_id, service_key, group_key)
#);
#
#-- Single domains switched off inside a group the template otherwise routes.
#--
#-- Recorded as exceptions rather than as the full list of what is routed, so
#-- that a group means "everything in this group" and keeps meaning it when the
#-- catalogue grows. A domain added to Spotify next month starts routing for
#-- every template that routes Spotify - which is what an operator who ticked
#-- Spotify asked for - while the handful they deliberately switched off stay
#-- off. No domain is in two groups, so the domain alone identifies the row.
#CREATE TABLE IF NOT EXISTS template_domains_off (
#    template_id INTEGER NOT NULL REFERENCES templates(id) ON DELETE CASCADE,
#    domain      TEXT NOT NULL,
#    PRIMARY KEY (template_id, domain)
#);
#
#-- Browser sessions for the user panel. The relay serves the pages but keeps
#-- no state: it holds the cookie and asks here who it belongs to, so a relay
#-- being rebuilt does not log everybody out, and a second relay serves the same
#-- session without anything being shared between them.
#CREATE TABLE IF NOT EXISTS panel_sessions (
#    token      TEXT PRIMARY KEY,
#    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
#    created_at TEXT NOT NULL,
#    expires_at TEXT NOT NULL
#);
#
#-- Where each address's counter stood at the last sync, per relay.
#--
#-- Per relay, not per address. Every relay reports its own counter for the same
#-- customer, and one shared figure makes them overwrite each other: the relay
#-- reporting the smaller number looks like a counter reset, the next relay's
#-- larger number then looks like fresh traffic, and the same bytes are charged
#-- again every cycle. Two relays turned 52 GB of real usage into 12.6 TB in a
#-- day. Invisible with a single relay, which is why it survived until there
#-- were two.
#CREATE TABLE IF NOT EXISTS ip_counters (
#    ip           TEXT NOT NULL,
#    relay        TEXT NOT NULL,
#    last_counter INTEGER NOT NULL DEFAULT 0,
#    PRIMARY KEY (ip, relay)
#);
#
#-- Domains the operator added themselves, on top of the list that ships with
#-- the installer. Kept here rather than edited on each relay so that one entry
#-- reaches every relay, and survives a relay being rebuilt from scratch.
#CREATE TABLE IF NOT EXISTS custom_domains (
#    domain   TEXT PRIMARY KEY,
#    note     TEXT,
#    added_at TEXT NOT NULL
#);
#
#-- Host health, one row per sample per machine. Written every thirty seconds
#-- by whatever reports it, and pruned to a day, which at that rate is a few
#-- thousand rows per host - small enough to keep in the same database rather
#-- than standing up something separate to hold it.
#CREATE TABLE IF NOT EXISTS metrics (
#    id         INTEGER PRIMARY KEY,
#    host       TEXT NOT NULL,
#    at         TEXT NOT NULL,
#    cpu        REAL,
#    load       REAL,
#    mem_used   INTEGER,
#    mem_total  INTEGER,
#    swap_used  INTEGER,
#    swap_total INTEGER,
#    disk_used  INTEGER,
#    disk_total INTEGER,
#    rx_bps     INTEGER,
#    tx_bps     INTEGER,
#    uptime     INTEGER
#);
#CREATE INDEX IF NOT EXISTS metrics_host_at ON metrics(host, at);
#"""
#
#METRIC_FIELDS = ("cpu", "load", "mem_used", "mem_total", "swap_used",
#                 "swap_total", "disk_used", "disk_total", "rx_bps", "tx_bps",
#                 "uptime")
#
## How long health samples are kept. A day is enough to answer "was it the
## server?" about something that happened this morning, and short enough that
## the table never becomes the largest thing in the database.
#METRICS_KEEP_HOURS = 24
#
## Columns added after the first release. sqlite has no ADD COLUMN IF NOT
## EXISTS, so these are applied only when the column is genuinely missing.
#MIGRATIONS = [
#    # Which warning thresholds this user has already been told about, so a
#    # sync every thirty seconds does not send the same warning a hundred times.
#    ("users", "warned", "INTEGER NOT NULL DEFAULT 0"),
#    # Null means the default template, so existing accounts keep working
#    # unchanged when this arrives.
#    ("users", "template_id", "INTEGER REFERENCES templates(id)"),
#    # Web signup. Added by ALTER on databases that predate it; the UNIQUE on
#    # phone lives in the index below, because ADD COLUMN cannot carry one.
#    ("users", "phone", "TEXT"),
#    ("users", "password_hash", "TEXT"),
#    ("users", "password_salt", "TEXT"),
#    # Download limit in kilobits per second; 0 means no limit, which is what
#    # every account that predates this gets.
#    ("users", "speed_kbps", "INTEGER NOT NULL DEFAULT 0"),
#    ("users", "expires_at", "TEXT"),
#    ("transactions", "receipt_blob", "BLOB"),
#    ("transactions", "receipt_type", "TEXT"),
#    ("transactions", "note", "TEXT"),
#]
#
## Indexes that have to exist whether the table was created by SCHEMA or grown
## by MIGRATIONS. A unique index and a UNIQUE column constraint are the same
## thing to sqlite, so this makes both paths end up identical.
#INDEXES = [
#    "CREATE UNIQUE INDEX IF NOT EXISTS users_phone ON users(phone)",
#    # What a customer signs in with. The column predates this - it held the
#    # Telegram handle - and sqlite cannot add UNIQUE to a column that is
#    # already there, so the constraint arrives as an index instead. Nulls do
#    # not collide in a unique index, which is what accounts that never had one
#    # need.
#    "CREATE UNIQUE INDEX IF NOT EXISTS users_username ON users(username)",
#]
#
## Where the installer puts the service catalogue - which brands exist, which
## groups each has, and which domains are in each group.
#SERVICES_FILE = "/usr/local/share/smart-dns/services.json"
#
## Ceiling on distinct templates actually in use. Each one is a dnsmasq
## instance on every relay, with its own cache and its own port, so this is a
## real resource limit rather than a preference. Eight plans is more than any
## of this is likely to need; the panel refuses to exceed it rather than
## quietly starting a ninth resolver on every machine.
#MAX_TEMPLATES = 8
#
#MB = 1024 ** 2
#GB = 1024 ** 3
#
## A photograph of a bank slip. Generous for a phone camera, small enough that
## a few pending ones cannot bloat the database or a backup.
#MAX_RECEIPT = 4 * MB
#
## What the service is called and what a new account gets. Kept in the database
## rather than in this file, so changing either is an edit in the admin panel
## rather than a redeploy to every machine.
#DEFAULT_SETTINGS = {
#    # No trial. A new account gets nothing until an operator gives it
#    # something - see create_web_user.
#    "plan_bytes": str(2 * GB),
#    "plan_days": "30",
#}
#
## Fractions of the quota at which the user is warned, and the bit each one
## sets in users.warned.
#THRESHOLDS = [(0.80, 1), (0.95, 2)]
#
#IPV4 = re.compile(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$")
#
#
#class Throttle:
#    """Counts recent attempts per key, in memory.
#
#    The panel is one process, so a dict is the whole implementation. Losing the
#    counts on restart is acceptable: this exists to make guessing slow, and a
#    restart is not something an attacker can cause.
#    """
#
#    def __init__(self):
#        self.lock = threading.Lock()
#        self.hits = {}
#
#    def _prune(self, key, window):
#        cutoff = time.time() - window
#        kept = [t for t in self.hits.get(key, []) if t > cutoff]
#        if kept:
#            self.hits[key] = kept
#        else:
#            self.hits.pop(key, None)
#        return kept
#
#    def check(self, key, limit, window):
#        """(allowed, seconds until the oldest attempt falls out of the window)"""
#        with self.lock:
#            kept = self._prune(key, window)
#            if len(kept) < limit:
#                return True, 0
#            return False, int(window - (time.time() - kept[0])) + 1
#
#    def hit(self, key):
#        with self.lock:
#            self.hits.setdefault(key, []).append(time.time())
#
#    def clear(self, key):
#        with self.lock:
#            self.hits.pop(key, None)
#
#
#THROTTLE = Throttle()
#
#
#def now():
#    return datetime.now(timezone.utc).isoformat(timespec="seconds")
#
#
#def parse_ts(s):
#    """Parse a stored timestamp as an aware UTC datetime, or None.
#
#    Everything this program writes carries an offset, but the database is also
#    edited by hand and by admin scripts, and sqlite's own datetime() produces a
#    naive string. Comparing one of those against an aware value raises, which
#    is how the whole quota pass once died on every sync. Assume UTC when no
#    offset is given, since that is what every writer here means.
#    """
#    if not s:
#        return None
#    try:
#        t = datetime.fromisoformat(s)
#    except ValueError:
#        return None
#    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)
#
#
#def valid_ip(s):
#    m = IPV4.match(s or "")
#    return bool(m) and all(0 <= int(p) <= 255 for p in m.groups())
#
#
#def normal_phone(s):
#    """Reduce an Iranian mobile number to one canonical form, or return "".
#
#    People type the same number four ways - 0912…, 912…, +98912…, ۰۹۱۲… - and
#    all four have to collide, or one person ends up with four accounts and the
#    operator cannot match a card receipt to any of them.
#    """
#    digits = ""
#    for ch in (s or "").strip():
#        if ch.isdigit():
#            # Persian and Arabic-Indic digits: unicodedata.digit maps both.
#            digits += str(unicodedata.digit(ch))
#    if digits.startswith("0098"):
#        digits = digits[4:]
#    elif digits.startswith("98") and len(digits) == 12:
#        digits = digits[2:]
#    elif digits.startswith("0"):
#        digits = digits[1:]
#    # 9xxxxxxxxx - a mobile number without the leading zero.
#    if len(digits) == 10 and digits.startswith("9"):
#        return "0" + digits
#    return ""
#
#
#def normal_username(s):
#    """Reduce a username to one canonical form, or return "".
#
#    Lowercased, because somebody who signs up as Ali and comes back as ali is
#    the same person and must not be able to become two accounts - nor be told
#    their own name is taken. Letters, digits, dot, dash and underscore only:
#    this ends up in log lines and in the operator's panel, and a name carrying
#    spaces or control characters is a nuisance in both.
#    """
#    v = (s or "").strip().lower()
#    if not re.fullmatch(r"[a-z0-9._-]{3,32}", v):
#        return ""
#    # A name that is only punctuation is not a name.
#    if not any(c.isalnum() for c in v):
#        return ""
#    return v
#
#
#def hash_password(password, salt):
#    # Same cost as the admin panel: slow enough that a stolen database is not
#    # a list of passwords, fast enough that signing in is not noticeable.
#    return hashlib.pbkdf2_hmac(
#        "sha256", (password or "").encode(), bytes.fromhex(salt), 200_000).hex()
#
#
#def check_password(user, password):
#    if not user["password_hash"] or not user["password_salt"]:
#        return False
#    return hmac.compare_digest(
#        hash_password(password, user["password_salt"]), user["password_hash"])
#
#
#def human(n):
#    n = float(n)
#    for unit in ("B", "KB", "MB", "GB", "TB"):
#        if n < 1024 or unit == "TB":
#            return ("%d %s" if unit == "B" else "%.2f %s") % (n, unit)
#        n /= 1024
#
#
#DOMAIN_RE = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+"
#                       r"[a-z]{2,63}$")
#
## Names that must never be routed to the relay. localhost and the internal
## suffixes would break name resolution on the machine itself. Telegram stays on
## the list because customers reach support through it and a relay answering for
## t.me would break that for everyone behind it.
#FORBIDDEN = ("localhost", "local", "internal", "arpa", "telegram.org",
#             "t.me", "telegram.me")
#
#
#def clean_domain(raw):
#    """Normalise what someone typed into a domain, or explain why it is not.
#
#    Accepts what people actually paste - a full URL, a trailing slash, capital
#    letters, a leading dot or www - because rejecting those teaches nothing and
#    just costs a round trip.
#    """
#    d = (raw or "").strip().lower()
#    d = re.sub(r"^[a-z]+://", "", d)      # scheme
#    d = d.split("/")[0].split("?")[0]     # path, query
#    d = d.split("@")[-1]                  # someone pasting an email
#    d = d.split(":")[0]                   # port
#    d = d.strip(".")
#    if not d:
#        raise ValueError("خالی است")
#    if not DOMAIN_RE.match(d):
#        raise ValueError("قالب دامنه درست نیست")
#    if any(d == f or d.endswith("." + f) for f in FORBIDDEN):
#        raise ValueError("این دامنه را نمی‌شود مسیر داد")
#    if d.count(".") == 1 and len(d.split(".")[0]) <= 2:
#        raise ValueError("خیلی کلی است - دامنهٔ کامل بدهید")
#    return d
#
#
#def inspect_backup(path):
#    """Check a file really is one of our backups, and say what is in it.
#
#    Raises rather than returning a verdict, because every caller wants to stop.
#    A file that opens as sqlite is not enough: someone's unrelated database
#    would pass that and then replace every customer with nothing.
#    """
#    db = sqlite3.connect(path)
#    try:
#        status = db.execute("PRAGMA integrity_check").fetchone()[0]
#        if status != "ok":
#            raise ValueError("integrity check failed: %s" % status)
#        have = {r[0] for r in db.execute(
#            "SELECT name FROM sqlite_master WHERE type = 'table'")}
#        missing = {"users", "ips", "templates", "settings"} - have
#        if missing:
#            raise ValueError("not a panel backup - missing %s"
#                             % ", ".join(sorted(missing)))
#        return {t: db.execute("SELECT count(*) FROM " + t).fetchone()[0]
#                for t in ("users", "ips", "templates", "transactions")}
#    finally:
#        db.close()
#
#
## The operator's own domains, presented as a service so a template can include
## or exclude them like any brand. Its domain list lives in the database rather
## than the catalogue file, so it is filled in at use rather than shipped.
#CUSTOM_SERVICE = {"key": "custom", "label": "دامنه‌های دلخواه شما",
#                  "groups": [{"key": "main", "label": "همه", "domains": []}]}
#
#
#def load_catalogue():
#    """The service catalogue the installer dropped alongside this script.
#
#    Shipped as a file rather than kept in the database so that it is versioned
#    with the code: adding a brand is an upgrade, not a migration, and every
#    relay and panel agrees on what "playstation.download" means.
#    """
#    try:
#        with io_open(SERVICES_FILE) as fh:
#            return json.load(fh).get("services", [])
#    except Exception as e:
#        print("no service catalogue at %s: %s" % (SERVICES_FILE, e),
#              file=sys.stderr, flush=True)
#        return []
#
#
#def io_open(path):
#    return open(path, encoding="utf-8")
#
#
#def load_config():
#    cfg = {}
#    with open(CONFIG) as fh:
#        for line in fh:
#            line = line.strip()
#            if not line or line.startswith("#") or "=" not in line:
#                continue
#            k, v = line.split("=", 1)
#            cfg[k.strip()] = v.strip().strip('"').strip("'")
#    for required in ("SYNC_SECRET", "RELAY_IP"):
#        if not cfg.get(required):
#            sys.exit("%s: %s is missing" % (CONFIG, required))
#    return cfg
#
#
## --------------------------------------------------------------- database
#def relax_telegram_id(db, path):
#    """Drop the NOT NULL from users.telegram_id on databases that predate web
#    signup.
#
#    sqlite cannot alter a column constraint, so the table has to be rebuilt.
#    The new definition is not written out here - it is the existing one with
#    that one phrase removed - so any column added by a later MIGRATIONS entry
#    survives without this function knowing it exists.
#
#    A copy of the database is taken first. This runs at startup, before the bot
#    is polling and before any relay can reach the API, and if it goes wrong the
#    operator has the file it went wrong on.
#    """
#    row = db.execute("SELECT sql FROM sqlite_master"
#                     " WHERE type = 'table' AND name = 'users'").fetchone()
#    if not row:
#        return
#    old = row[0]
#    new = re.sub(r"(telegram_id\s+INTEGER\s+UNIQUE)\s+NOT\s+NULL", r"\1",
#                 old, flags=re.I)
#    if new == old:
#        return                      # already nullable, nothing to do
#
#    backup = "%s.pre-websignup" % path
#    db.commit()                     # VACUUM cannot run inside a transaction
#    if not os.path.exists(backup):
#        db.execute("VACUUM INTO ?", (backup,))
#    print("migrating users: telegram_id may now be null (backup: %s)" % backup,
#          flush=True)
#
#    new = re.sub(r"^\s*CREATE\s+TABLE\s+(IF\s+NOT\s+EXISTS\s+)?[\"'`\[]?users[\"'`\]]?",
#                 "CREATE TABLE users_new", new, count=1, flags=re.I)
#    cols = [r[1] for r in db.execute("PRAGMA table_info(users)")]
#    names = ", ".join('"%s"' % c for c in cols)
#
#    # Foreign keys off for the swap: ips, claims, transactions and
#    # panel_sessions all point at users(id), and dropping the table underneath
#    # them with enforcement on would either fail or take their rows with it.
#    # It cannot be toggled inside a transaction, hence the order here.
#    db.execute("PRAGMA foreign_keys = OFF")
#    try:
#        db.execute("BEGIN")
#        db.execute(new)
#        db.execute("INSERT INTO users_new (%s) SELECT %s FROM users" % (names, names))
#        db.execute("DROP TABLE users")
#        db.execute("ALTER TABLE users_new RENAME TO users")
#        db.execute("COMMIT")
#    except Exception:
#        db.execute("ROLLBACK")
#        db.execute("PRAGMA foreign_keys = ON")
#        raise
#    broken = db.execute("PRAGMA foreign_key_check").fetchall()
#    db.execute("PRAGMA foreign_keys = ON")
#    if broken:
#        raise RuntimeError("migration left %d dangling references - the "
#                           "database before it is at %s" % (len(broken), backup))
#
#
#class Store:
#    """All database access, with one lock around it.
#
#    Two threads touch the database - the Telegram loop and the sync API - and
#    sqlite3 connections are not safe to share across threads. One connection
#    guarded by a lock is simpler to reason about than a pool, and at this size
#    there is nothing to gain from the pool.
#    """
#
#    def __init__(self, path):
#        self.lock = threading.Lock()
#        self.db = sqlite3.connect(path, check_same_thread=False)
#        self.db.row_factory = sqlite3.Row
#        self.db.execute("PRAGMA foreign_keys = ON")
#        self.db.execute("PRAGMA journal_mode = WAL")
#        with self.lock:
#            self.db.executescript(SCHEMA)
#            relax_telegram_id(self.db, path)
#            for table, column, spec in MIGRATIONS:
#                have = {r[1] for r in self.db.execute("PRAGMA table_info(%s)" % table)}
#                if column not in have:
#                    self.db.execute(
#                        "ALTER TABLE %s ADD COLUMN %s %s" % (table, column, spec)
#                    )
#            for statement in INDEXES:
#                self.db.execute(statement)
#            for key, value in DEFAULT_SETTINGS.items():
#                self.db.execute(
#                    "INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)",
#                    (key, value),
#                )
#            self.db.commit()
#
#    def setting(self, key, default=""):
#        row = self.one("SELECT value FROM settings WHERE key = ?", (key,))
#        return row["value"] if row else default
#
#    def set_setting(self, key, value):
#        self.run(
#            "INSERT INTO settings (key, value) VALUES (?, ?)"
#            " ON CONFLICT(key) DO UPDATE SET value = excluded.value",
#            (key, str(value)),
#        )
#
#    def q(self, sql, args=()):
#        with self.lock:
#            return self.db.execute(sql, args).fetchall()
#
#    def one(self, sql, args=()):
#        rows = self.q(sql, args)
#        return rows[0] if rows else None
#
#    def run(self, sql, args=()):
#        with self.lock:
#            cur = self.db.execute(sql, args)
#            self.db.commit()
#            return cur
#
#    def user_by_telegram(self, tg_id):
#        return self.one("SELECT * FROM users WHERE telegram_id = ?", (tg_id,))
#
#    # A new account starts with nothing and is not connected: 'pending' keeps
#    # it out of the allowed list, which is what "no trial" has to mean, and
#    # the operator turns it on by giving it a quota.
#    #
#    # Not quota_bytes = 0 on an active account, which is the trap here: zero
#    # means unlimited everywhere in this file, so the account that was meant
#    # to get nothing would get everything. The status is what decides.
#    def create_user(self, tg_id, username, first_name):
#        self.run(
#            "INSERT OR IGNORE INTO users"
#            " (telegram_id, username, first_name, created_at, status,"
#            "  quota_bytes, quota_mode, quota_reset_at, expires_at)"
#            " VALUES (?, ?, ?, ?, 'pending', 0, 'oneoff', NULL, NULL)",
#            (tg_id, username, first_name, now()),
#        )
#        return self.user_by_telegram(tg_id)
#
#    def user_by_phone(self, phone):
#        return self.one("SELECT * FROM users WHERE phone = ?", (phone,))
#
#    def user_by_username(self, username):
#        return self.one("SELECT * FROM users WHERE username = ?", (username,))
#
#    def create_web_user(self, username, first_name, password):
#        """Open an account from the web panel, with no Telegram behind it.
#
#        It starts with nothing, the same as one opened any other way - the way
#        in should not decide what you get. Signing up gets you an account, a
#        password and somewhere to send a receipt; it does not get you any
#        traffic until an operator says so.
#        """
#        salt = secrets.token_hex(16)
#        self.run(
#            "INSERT INTO users"
#            " (telegram_id, username, password_hash, password_salt, first_name,"
#            "  created_at, status, quota_bytes, quota_mode, quota_reset_at,"
#            "  expires_at)"
#            " VALUES (NULL, ?, ?, ?, ?, ?, 'pending', 0, 'oneoff', NULL, NULL)",
#            (username, hash_password(password, salt), salt, first_name, now()),
#        )
#        return self.user_by_username(username)
#
#    def set_password(self, user_id, password):
#        salt = secrets.token_hex(16)
#        self.run("UPDATE users SET password_hash = ?, password_salt = ?"
#                 " WHERE id = ?", (hash_password(password, salt), salt, user_id))
#
#    def open_session(self, user_id, days=30):
#        token = secrets.token_urlsafe(32)
#        self.run(
#            "INSERT INTO panel_sessions (token, user_id, created_at, expires_at)"
#            " VALUES (?, ?, ?, ?)",
#            (token, user_id, now(),
#             (datetime.now(timezone.utc) + timedelta(days=days)).isoformat(
#                 timespec="seconds")))
#        return token
#
#    def user_ips(self, user_id):
#        return self.q("SELECT * FROM ips WHERE user_id = ? ORDER BY added_at", (user_id,))
#
#    def allowed(self):
#        return self.q(
#            "SELECT i.ip AS ip, u.id AS uid FROM ips i JOIN users u ON u.id = i.user_id"
#            " WHERE u.status = 'active'"
#        )
#
#    # ----------------------------------------------------------- templates
#    def ensure_default_template(self, catalogue):
#        """Create the all-services template if there is none.
#
#        Everything routes in it, which is exactly how the service behaved
#        before templates existed - so an upgrade changes nothing until an
#        admin decides otherwise.
#        """
#        row = self.one("SELECT * FROM templates WHERE is_default = 1")
#        if row:
#            return row
#        cur = self.run(
#            "INSERT INTO templates (name, is_default, created_at) VALUES (?, 1, ?)",
#            ("کامل", now()))
#        tid = cur.lastrowid
#        for svc in catalogue:
#            for grp in svc["groups"]:
#                # Opt-in groups are left out here too. The default template
#                # ignores these rows while it is the default, but it stops
#                # being special the moment somebody makes another one the
#                # default - and it should not carry a tick nobody made.
#                if grp.get("opt_in"):
#                    continue
#                self.run(
#                    "INSERT OR IGNORE INTO template_services"
#                    " (template_id, service_key, group_key) VALUES (?, ?, ?)",
#                    (tid, svc["key"], grp["key"]))
#        return self.one("SELECT * FROM templates WHERE id = ?", (tid,))
#
#    def template_groups(self, template_id):
#        return {(r["service_key"], r["group_key"]) for r in self.q(
#            "SELECT service_key, group_key FROM template_services WHERE template_id = ?",
#            (template_id,))}
#
#    def routed_for(self, template_id, catalogue):
#        """Domains this template DOES route, for the relay to hijack.
#
#        The relay writes these as address= rules in the profile's own
#        resolver, rather than inheriting the shared hijack list and taking
#        names back out of it with server= rules. Subtraction cannot work
#        here: both rules would name the same host, dnsmasq's longest match
#        ties, and address= wins - so every un-tick of an ordinary domain was
#        silently ignored. What a profile must not route, it must simply not
#        be told about.
#
#        The custom service is excluded: those domains reach the relay by a
#        different route, and apply_custom_domains writes them per profile.
#        """
#        routed = self.template_groups(template_id)
#        off = self.template_domains_off(template_id)
#        is_default = bool(self.one(
#            "SELECT is_default FROM templates WHERE id = ?",
#            (template_id,))["is_default"])
#        out = []
#        for svc in catalogue:
#            if svc["key"] == "custom":
#                continue
#            for grp in svc["groups"]:
#                # The default template means "everything, now and later", and
#                # the one exception is a group nobody has opted in to.
#                if is_default:
#                    if not grp.get("opt_in"):
#                        out.extend(grp["domains"])
#                    continue
#                if (svc["key"], grp["key"]) in routed:
#                    out.extend(d for d in grp["domains"] if d not in off)
#        return sorted(set(out))
#
#    def bypass_for(self, template_id, catalogue):
#        """Domains this template does NOT route, so the relay resolves them
#        normally and the client goes straight to them."""
#        # The default template means "everything", and has to keep meaning it
#        # as the catalogue grows. Reading its rows would freeze it at whatever
#        # existed the day it was created, so a brand added in a later upgrade
#        # would silently stop routing for every customer on the default plan -
#        # a service quietly getting worse with no change anybody made.
#        #
#        # "Everything" stops at the opt-in groups. Those exist so an operator
#        # can see them and decide; routing one by default would be deciding
#        # for them, in the one direction that breaks something.
#        row = self.one("SELECT is_default FROM templates WHERE id = ?", (template_id,))
#        if row and row["is_default"]:
#            return sorted({d for svc in catalogue for grp in svc["groups"]
#                           if grp.get("opt_in") for d in grp["domains"]})
#        routed = self.template_groups(template_id)
#        off = self.template_domains_off(template_id)
#        out = []
#        for svc in catalogue:
#            # Custom domains are never bypassed by rule - see routes_custom.
#            if svc["key"] == "custom":
#                continue
#            for grp in svc["groups"]:
#                if (svc["key"], grp["key"]) not in routed:
#                    out.extend(grp["domains"])
#                else:
#                    # The group is routed, minus whatever was switched off
#                    # inside it one domain at a time.
#                    out.extend(d for d in grp["domains"] if d in off)
#        return sorted(set(out))
#
#    def template_domains_off(self, template_id):
#        return {r["domain"] for r in self.q(
#            "SELECT domain FROM template_domains_off WHERE template_id = ?",
#            (template_id,))}
#
#    def profiles(self, catalogue, default_id):
#        """The templates actually in use, and who is on each.
#
#        Only templates with at least one active registered address become
#        profiles: an unused template costs a resolver on every relay for
#        nobody's benefit.
#        """
#        rows = self.q(
#            "SELECT i.ip AS ip, u.id AS uid, u.speed_kbps AS kbps,"
#            " COALESCE(u.template_id, ?) AS tid"
#            " FROM ips i JOIN users u ON u.id = i.user_id"
#            " WHERE u.status = 'active'", (default_id,))
#        by_ip = {}
#        used = set()
#        for r in rows:
#            tid = r["tid"] if self.one(
#                "SELECT 1 FROM templates WHERE id = ?", (r["tid"],)) else default_id
#            by_ip[r["ip"]] = {"uid": r["uid"], "tid": tid,
#                              "kbps": r["kbps"] or 0}
#            used.add(tid)
#        custom = self.custom_domains()
#        profiles = {}
#        for tid in used:
#            # The default routes everything, which is what the relay's main
#            # resolver already does - it needs no instance of its own.
#            if tid == default_id:
#                continue
#            profiles[str(tid)] = {
#                # What this template routes, said positively. The relay used
#                # to inherit the shared hijack list and subtract from it with
#                # server= rules, which dnsmasq resolved the other way whenever
#                # both named the same host - so an un-ticked service kept
#                # routing and nothing said otherwise.
#                "routed": self.routed_for(tid, catalogue),
#                # Still sent: names whose parent this template routes have to
#                # be taken back out, and there the subtraction does work,
#                # because the profile's rule is the longer one.
#                "bypass": self.bypass_for(tid, catalogue),
#                # Listed positively, not by omission: the relay writes these
#                # into this profile's own config, and a template that does not
#                # route them simply has no rule for them anywhere.
#                "custom": custom if self.routes_custom(tid) else [],
#                # Whether this profile still wants epic-pin's work. Those pins
#                # name exact hosts, so they beat any rule that routes the
#                # parent domain - which means a template that has ticked the
#                # backend group would tick it and see nothing happen. The
#                # relay leaves the pins out of a profile that asked to route
#                # them, and keeps them everywhere else.
#                "pins": ("bypass", "epic") not in self.template_groups(tid),
#            }
#        return by_ip, profiles
#
#    def custom_domains(self):
#        return [r["domain"] for r in self.q(
#            "SELECT domain FROM custom_domains ORDER BY domain")]
#
#    def routes_custom(self, template_id):
#        """Whether this template routes the operator's own domains.
#
#        These cannot be handled the way catalogue services are. A service is
#        un-routed by adding a more specific `server=` rule that out-matches the
#        broad `address=` hijacking its parent - but a custom domain's two rules
#        name exactly the same host, and dnsmasq picks the address= one. Tested,
#        not assumed. So rather than un-routing them per template, they are
#        written only into the resolvers of templates that do route them.
#        """
#        row = self.one("SELECT is_default FROM templates WHERE id = ?", (template_id,))
#        if row and row["is_default"]:
#            return True
#        return ("custom", "main") in self.template_groups(template_id)
#
#    def backup(self):
#        """A consistent copy of the database, minus the metrics.
#
#        VACUUM INTO rather than copying the file: sqlite is in WAL mode, so the
#        file on disk is not the whole story and copying it while the bot is
#        writing can produce something that will not open. VACUUM INTO takes a
#        proper snapshot with the database still running.
#
#        Health samples are dropped from the copy. They are the bulk of the rows
#        and none of the value - what matters in a restore is who the customers
#        are, what they bought and what they have used.
#        """
#        path = "/tmp/smartdns-backup-%s.db" % datetime.now(timezone.utc).strftime(
#            "%Y%m%d-%H%M%S")
#        with self.lock:
#            self.db.execute("VACUUM INTO ?", (path,))
#        copy = sqlite3.connect(path)
#        copy.execute("DELETE FROM metrics")
#        copy.commit()
#        copy.execute("VACUUM")
#        copy.close()
#        return path
#
#    def restore(self, path):
#        """Put a checked backup in place of the live database.
#
#        The current database is kept, not deleted: a restore is exactly the
#        moment somebody discovers they restored the wrong file, and having the
#        previous state one move away is the difference between an inconvenience
#        and losing every customer.
#
#        The candidate has to be staged beside the database, not in /tmp.
#        rename() cannot cross a mount point, and the unit sets PrivateTmp, so
#        /tmp is one - a restore from there fails with EXDEV at the last step,
#        after the safety copy has been taken and the connection closed.
#        """
#        if os.path.dirname(os.path.abspath(path)) != os.path.dirname(DB):
#            staged = os.path.join(os.path.dirname(DB),
#                                  ".restore-%s.db" % secrets.token_hex(6))
#            shutil.copyfile(path, staged)
#            os.unlink(path)
#            path = staged
#        keep = "%s.before-restore-%s" % (
#            DB, datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S"))
#        with self.lock:
#            self.db.execute("VACUUM INTO ?", (keep,))
#            self.db.close()
#        os.replace(path, DB)
#        # A stale write-ahead log next to a different database is how a restore
#        # turns into corruption. The backup is a complete snapshot, so there is
#        # nothing in these worth keeping.
#        for suffix in ("-wal", "-shm"):
#            try:
#                os.unlink(DB + suffix)
#            except OSError:
#                pass
#        return keep
#
#    def record_metrics(self, host, sample):
#        if not isinstance(sample, dict) or "error" in sample:
#            return
#        cols = [f for f in METRIC_FIELDS if sample.get(f) is not None]
#        # An empty sample builds "INSERT INTO metrics (host, at, ) VALUES ..",
#        # which sqlite rejects and which took the whole sync request down with
#        # it - a relay running an older agent sends no metrics at all, and that
#        # must not stop its usage being counted.
#        if not cols:
#            return
#        self.run(
#            "INSERT INTO metrics (host, at, %s) VALUES (?, ?, %s)"
#            % (", ".join(cols), ", ".join("?" * len(cols))),
#            [host, now()] + [sample[c] for c in cols],
#        )
#
#    def prune_metrics(self):
#        self.run(
#            "DELETE FROM metrics WHERE at < ?",
#            ((datetime.now(timezone.utc)
#              - timedelta(hours=METRICS_KEEP_HOURS)).isoformat(timespec="seconds"),))
#
#    def latest_metrics(self):
#        """Newest sample per host."""
#        return self.q(
#            "SELECT m.* FROM metrics m JOIN ("
#            "  SELECT host, MAX(at) AS at FROM metrics GROUP BY host"
#            ") last ON last.host = m.host AND last.at = m.at"
#        )
#
#    def fold_counters(self, relay, counters):
#        """Turn raw per-address counters into per-user usage.
#
#        The kernel counts bytes per address since the element was created. What
#        a bill needs is bytes per user, across whatever addresses they have had.
#        So take the growth since last time rather than the absolute number, and
#        add it to the user's running total.
#
#        The previous reading is kept per relay - see ip_counters. Sharing one
#        figure between relays bills the same bytes over and over.
#        """
#        touched = {}
#        with self.lock:
#            for ip, total in counters.items():
#                row = self.db.execute(
#                    "SELECT id, user_id FROM ips WHERE ip = ?", (ip,)).fetchone()
#                if row is None:
#                    continue
#                prev = self.db.execute(
#                    "SELECT last_counter FROM ip_counters WHERE ip = ? AND relay = ?",
#                    (ip, relay)).fetchone()
#                # A counter that went backwards means it was reset - a reboot
#                # restoring an older saved value, or the address being
#                # re-added. Whatever is there now is the growth.
#                delta = total - (prev["last_counter"] if prev else 0)
#                if delta < 0:
#                    delta = total
#                if delta:
#                    self.db.execute(
#                        "UPDATE users SET used_bytes = used_bytes + ? WHERE id = ?",
#                        (delta, row["user_id"]),
#                    )
#                    touched[row["user_id"]] = touched.get(row["user_id"], 0) + delta
#                self.db.execute(
#                    "INSERT INTO ip_counters (ip, relay, last_counter)"
#                    " VALUES (?, ?, ?) ON CONFLICT(ip, relay)"
#                    " DO UPDATE SET last_counter = excluded.last_counter",
#                    (ip, relay, total))
#            self.db.commit()
#        return touched
#
#
## ----------------------------------------------------------------- health
#class Health:
#    """This machine's own metrics, read straight out of /proc.
#
#    A near-copy of the same class in smartdns-sync. They are duplicated on
#    purpose: each program is extracted from the installer as a single
#    self-contained file, so a shared module would mean a third payload and a
#    third thing to keep in step.
#    """
#
#    def __init__(self):
#        self.cpu = None
#        self.net = None
#
#    @staticmethod
#    def _meminfo():
#        out = {}
#        with open("/proc/meminfo") as fh:
#            for line in fh:
#                k, _, v = line.partition(":")
#                out[k] = int(v.split()[0]) * 1024
#        return out
#
#    def _cpu_percent(self):
#        with open("/proc/stat") as fh:
#            parts = [int(x) for x in fh.readline().split()[1:]]
#        idle, total = parts[3] + parts[4], sum(parts)
#        prev, self.cpu = self.cpu, (idle, total)
#        if not prev:
#            return None
#        d_total = total - prev[1]
#        if d_total <= 0:
#            return None
#        return round(100.0 * (1 - (idle - prev[0]) / d_total), 1)
#
#    def _net_rates(self):
#        rx = tx = 0
#        with open("/proc/net/dev") as fh:
#            for line in fh.readlines()[2:]:
#                name, _, rest = line.partition(":")
#                if name.strip() == "lo":
#                    continue
#                f = rest.split()
#                rx += int(f[0]); tx += int(f[8])
#        stamp = time.time()
#        prev, self.net = self.net, (rx, tx, stamp)
#        if not prev:
#            return None, None
#        dt = stamp - prev[2]
#        if dt <= 0:
#            return None, None
#        return int((rx - prev[0]) / dt), int((tx - prev[1]) / dt)
#
#    def sample(self):
#        m = self._meminfo()
#        rx, tx = self._net_rates()
#        st = os.statvfs("/")
#        with open("/proc/uptime") as fh:
#            uptime = int(float(fh.readline().split()[0]))
#        with open("/proc/loadavg") as fh:
#            load = float(fh.readline().split()[0])
#        swap_total = m.get("SwapTotal", 0)
#        return {
#            "cpu": self._cpu_percent(),
#            "load": load,
#            "mem_total": m.get("MemTotal", 0),
#            "mem_used": m.get("MemTotal", 0) - m.get("MemAvailable", 0),
#            "swap_total": swap_total,
#            "swap_used": swap_total - m.get("SwapFree", 0) if swap_total else 0,
#            "disk_total": st.f_blocks * st.f_frsize,
#            "disk_used": (st.f_blocks - st.f_bfree) * st.f_frsize,
#            "rx_bps": rx,
#            "tx_bps": tx,
#            "uptime": uptime,
#        }
#
#
## ------------------------------------------------------------------ quota
#def enforce_quotas(store):
#    """Reset, warn and cut off. Called after every sync.
#
#    Cutting off is a status change and nothing more. The relay learns about it
#    on its next sync, when the address stops appearing in the allowed list and
#    smartdns-acl removes it from the kernel. Nothing here touches a firewall
#    directly - one place decides who may connect, and it is the database.
#
#    Nothing is sent anywhere either. The warning thresholds are recorded in
#    users.warned and the customer is told on their own panel page, which
#    reaches everybody - most accounts have no Telegram behind them and never
#    did, so a message was only ever going to some of them.
#    """
#    stamp = datetime.now(timezone.utc)
#    for u in store.q("SELECT * FROM users"):
#        quota, used = u["quota_bytes"], u["used_bytes"]
#
#        # A trial ends on its date whether or not the allowance ran out, so
#        # this comes before anything to do with bytes. Checked for every
#        # account, but only the trial sets a date - a paid account ends when
#        # its quota does.
#        due = parse_ts(u["expires_at"])
#        if due and stamp >= due:
#            if u["status"] == "active":
#                store.run("UPDATE users SET status = 'expired' WHERE id = ?",
#                          (u["id"],))
#                print("expired: user %d after %s" % (u["id"], human(used)),
#                      flush=True)
#            continue
#
#        # Monthly plans roll over on their own date rather than on the 1st, so
#        # a user who joins on the 20th gets a full month.
#        if u["quota_mode"] == "monthly" and u["quota_reset_at"]:
#            due = parse_ts(u["quota_reset_at"])
#            if due and stamp >= due:
#                days = int(store.setting("plan_days", "30") or 30)
#                store.run(
#                    "UPDATE users SET used_bytes = 0, warned = 0,"
#                    " status = CASE WHEN status = 'over_quota' THEN 'active' ELSE status END,"
#                    " quota_reset_at = ? WHERE id = ?",
#                    ((stamp + timedelta(days=days)).isoformat(timespec="seconds"), u["id"]),
#                )
#                continue
#
#        if not quota:            # unlimited
#            continue
#
#        if used >= quota and u["status"] == "active":
#            store.run("UPDATE users SET status = 'over_quota' WHERE id = ?", (u["id"],))
#            print("over quota: user %d at %s of %s"
#                  % (u["id"], human(used), human(quota)), flush=True)
#            continue
#
#        # Record each threshold as it is crossed, once. The bit is what makes
#        # it once - a sync runs every thirty seconds - and it is what the
#        # customer's own page reads to decide whether to warn them.
#        for fraction, bit in THRESHOLDS:
#            if used >= quota * fraction and not (u["warned"] & bit):
#                store.run("UPDATE users SET warned = warned | ? WHERE id = ?",
#                          (bit, u["id"]))
#
#
## --------------------------------------------------------------- sync API
#class API(http.server.BaseHTTPRequestHandler):
#    server_version = "smartdns"
#    store = None
#    secret = None
#    relays = ()
#    tg = None
#
#    def log_message(self, *a):
#        pass
#
#    def reply(self, code, obj):
#        body = json.dumps(obj).encode()
#        self.send_response(code)
#        self.send_header("Content-Type", "application/json")
#        self.send_header("Content-Length", str(len(body)))
#        self.end_headers()
#        self.wfile.write(body)
#
#    def authorised(self):
#        # This port is reachable from the whole internet, so the bearer token
#        # is not the only thing standing in front of the database. Only the
#        # relays this exit is paired with may talk to it at all - a scanner
#        # that finds the port gets nothing to guess against.
#        if self.client_address[0] not in self.relays:
#            return False
#        given = self.headers.get("Authorization", "")
#        want = "Bearer " + self.secret
#        # Constant time, so the comparison cannot be used to guess the secret
#        # one character at a time.
#        return hmac.compare_digest(given, want)
#
#    def do_POST(self):
#        if not self.authorised():
#            return self.reply(401, {"error": "unauthorised"})
#        try:
#            length = int(self.headers.get("Content-Length", 0))
#            # Base64 inflates by a third, and the largest thing a relay sends
#            # is a receipt. Anything past that is refused unread rather than
#            # buffered.
#            if length > 8 * MB:
#                return self.reply(413, {"error": "too large"})
#            body = json.loads(self.rfile.read(length) or b"{}")
#        except Exception:
#            return self.reply(400, {"error": "bad json"})
#
#        if self.path == "/sync":
#            counters = body.get("counters") or {}
#            clean = {
#                ip: int(v) for ip, v in counters.items() if valid_ip(ip) and int(v) >= 0
#            }
#            self.store.fold_counters(self.client_address[0], clean)
#            # The relay names itself by the address it connected from, so a
#            # second relay appears on its own without any configuration.
#            self.store.record_metrics(self.client_address[0], body.get("host") or {})
#            # Quotas are evaluated here, on fresh numbers, so a user who runs
#            # out is off the list this relay is about to be handed.
#            try:
#                enforce_quotas(self.store)
#            except Exception as e:
#                print("quota pass failed: %r" % e, file=sys.stderr, flush=True)
#            by_ip, profiles = self.store.profiles(CATALOGUE, DEFAULT_TEMPLATE[0])
#            # The label goes into the nftables element as a comment, so that
#            # `smartdns-acl list` on the relay is readable without the
#            # database in front of you. The profile tells the relay which
#            # resolver this address should be pointed at.
#            # uid travels as well as the label built from it: the relay uses
#            # it as the shaping mark, and parsing it back out of "u12" would
#            # be a second place that has to agree about the format.
#            allowed = [{"ip": ip, "name": "u%d" % v["uid"], "uid": v["uid"],
#                        "kbps": v["kbps"],
#                        "profile": str(v["tid"]) if str(v["tid"]) in profiles else ""}
#                       for ip, v in sorted(by_ip.items())]
#            extra = [r["domain"] for r in self.store.q(
#                "SELECT domain FROM custom_domains ORDER BY domain")]
#            return self.reply(200, {"allowed": allowed, "profiles": profiles,
#                                    "extra_domains": extra,
#                                    })
#
#        # ---- user panel, served by the relay on the customer's behalf ----
#        if self.path == "/user-info":
#            return self.reply(200, self.do_user_info(body))
#        if self.path == "/user-claim":
#            return self.reply(200, self.do_user_claim(body))
#        if self.path == "/user-signup":
#            return self.reply(200, self.do_user_signup(body))
#        if self.path == "/user-password-login":
#            return self.reply(200, self.do_user_password_login(body))
#        if self.path == "/user-receipt":
#            return self.reply(200, self.do_user_receipt(body))
#        if self.path == "/user-password":
#            return self.reply(200, self.do_user_password(body))
#
#        return self.reply(404, {"error": "no such endpoint"})
#
#    # ---- user panel ------------------------------------------------------
#    def _session_user(self, token):
#        row = self.store.one(
#            "SELECT u.* FROM panel_sessions s JOIN users u ON u.id = s.user_id"
#            " WHERE s.token = ? AND s.expires_at > ?", (token or "", now()))
#        return row
#
#    def do_user_signup(self, body):
#        """Open an account from the panel, with no Telegram in the way.
#
#        The address is not registered here. Signing up and pointing the service
#        at a connection are two different decisions - somebody may well sign up
#        on mobile data and only afterwards go and register the home line - so
#        the next page asks, showing the address it can see.
#        """
#        ip = body.get("ip", "")
#        ok, wait = THROTTLE.check("signup:%s" % ip, limit=4, window=3600)
#        if not ok:
#            return {"ok": False, "message":
#                    "تعداد ثبت‌نام از این اینترنت زیاد بوده. %d دقیقه دیگر."
#                    % max(1, wait // 60)}
#
#        username = normal_username(body.get("username"))
#        if not username:
#            return {"ok": False, "message":
#                    "نام کاربری باید ۳ تا ۳۲ نویسه باشد — حروف انگلیسی، عدد،"
#                    " و . _ -"}
#        password = body.get("password") or ""
#        if len(password) < 8:
#            return {"ok": False, "message": "رمز باید دست‌کم ۸ نویسه باشد"}
#        name = (body.get("name") or "").strip()[:60]
#
#        if self.store.user_by_username(username):
#            return {"ok": False,
#                    "message": "این نام کاربری قبلاً گرفته شده. یکی دیگر"
#                               " بنویسید یا وارد شوید"}
#        try:
#            user = self.store.create_web_user(username, name, password)
#        except sqlite3.IntegrityError:
#            # Two signups claiming the same name in the same instant. The
#            # unique index is what actually decides between them; this only
#            # turns its answer into a sentence.
#            return {"ok": False,
#                    "message": "این نام کاربری قبلاً گرفته شده. یکی دیگر"
#                               " بنویسید یا وارد شوید"}
#        THROTTLE.hit("signup:%s" % ip)
#        print("web signup: %s (#%d) from %s" % (username, user["id"], ip), flush=True)
#        return {"ok": True, "session": self.store.open_session(user["id"]),
#                "message": "حساب ساخته شد"}
#
#    def do_user_password_login(self, body):
#        ip = body.get("ip", "")
#        ok, wait = THROTTLE.check("login:%s" % ip, limit=8, window=900)
#        if not ok:
#            return {"ok": False, "message":
#                    "تلاش زیاد بوده. %d دقیقه دیگر امتحان کنید."
#                    % max(1, wait // 60)}
#
#        username = normal_username(body.get("username"))
#        user = self.store.user_by_username(username) if username else None
#        # One message for an unknown name and a wrong password. Two different
#        # messages tell anybody who asks which names have accounts.
#        if not user or not check_password(user, body.get("password") or ""):
#            THROTTLE.hit("login:%s" % ip)
#            return {"ok": False, "message": "نام کاربری یا رمز درست نیست"}
#        THROTTLE.clear("login:%s" % ip)
#        return {"ok": True, "session": self.store.open_session(user["id"])}
#
#    def do_user_password(self, body):
#        """Let a customer change their own password.
#
#        The current one is required even though the session already proves
#        who they are. A session can be a borrowed phone or a browser left
#        open; asking for the password again means possession of the session
#        is not enough to take the account away from its owner.
#        """
#        user = self._session_user(body.get("session"))
#        if not user:
#            return {"ok": False, "message": "نشست معتبر نیست"}
#        if not user["password_hash"]:
#            return {"ok": False,
#                    "message": "این حساب رمز ندارد؛ با پشتیبانی تماس بگیرید"}
#        if not check_password(user, body.get("current") or ""):
#            # Same throttle as signing in: this is a password guess like any
#            # other, and a stolen session should not buy unlimited attempts.
#            ok, wait = THROTTLE.check("pw:%d" % user["id"], limit=8, window=900)
#            if not ok:
#                return {"ok": False, "message":
#                        "تلاش زیاد بوده. %d دقیقه دیگر." % max(1, wait // 60)}
#            THROTTLE.hit("pw:%d" % user["id"])
#            return {"ok": False, "message": "رمز فعلی درست نیست"}
#
#        new = body.get("new") or ""
#        if len(new) < 8:
#            return {"ok": False, "message": "رمز تازه باید دست‌کم ۸ نویسه باشد"}
#        if new == (body.get("current") or ""):
#            return {"ok": False, "message": "رمز تازه با رمز فعلی یکی است"}
#
#        self.store.set_password(user["id"], new)
#        THROTTLE.clear("pw:%d" % user["id"])
#        # Every other session ends. Changing a password is what somebody does
#        # when they think another person has their account, so leaving that
#        # person signed in would defeat the whole exercise.
#        kept = body.get("session")
#        self.store.run(
#            "DELETE FROM panel_sessions WHERE user_id = ? AND token != ?",
#            (user["id"], kept))
#        print("password changed for user %d" % user["id"], flush=True)
#        return {"ok": True,
#                "message": "رمز عوض شد. اگر جای دیگری وارد بودید، خارج شدید"}
#
#    def do_user_receipt(self, body):
#        """Store a photograph of a payment slip against the customer.
#
#        The relay reads the upload and passes the bytes here base64-encoded,
#        so the image lands in the same database as everything else and one
#        backup covers it. Nothing about the account changes: this records a
#        claim, and the operator decides what it is worth.
#        """
#        user = self._session_user(body.get("session"))
#        if not user:
#            return {"ok": False, "message": "نشست معتبر نیست"}
#
#        kind = (body.get("content_type") or "").split(";")[0].strip().lower()
#        if kind not in ("image/jpeg", "image/png", "image/webp", "application/pdf"):
#            return {"ok": False,
#                    "message": "فقط عکس (JPG، PNG، WEBP) یا PDF قبول می‌شود"}
#        try:
#            blob = base64.b64decode(body.get("data") or "", validate=True)
#        except Exception:
#            return {"ok": False, "message": "فایل خراب بود، دوباره بفرستید"}
#        if not blob:
#            return {"ok": False, "message": "فایل خالی بود"}
#        if len(blob) > MAX_RECEIPT:
#            return {"ok": False, "message": "فایل بزرگ‌تر از %s است"
#                    % human(MAX_RECEIPT)}
#
#        # One pending receipt per customer. A second one replaces the first
#        # rather than queueing: somebody who sends three photographs of the
#        # same slip means the last one, and the operator should not have to
#        # work out which.
#        self.store.run(
#            "DELETE FROM transactions WHERE user_id = ? AND status = 'pending'",
#            (user["id"],))
#        try:
#            amount = max(0, int(body.get("amount") or 0))
#        except (TypeError, ValueError):
#            amount = 0
#        self.store.run(
#            "INSERT INTO transactions"
#            " (user_id, amount, kind, receipt_blob, receipt_type, note,"
#            "  status, created_at)"
#            " VALUES (?, ?, 'card', ?, ?, ?, 'pending', ?)",
#            (user["id"], amount, blob, kind,
#             (body.get("note") or "").strip()[:200], now()))
#        print("receipt from user %d: %s, %s"
#              % (user["id"], kind, human(len(blob))), flush=True)
#        return {"ok": True,
#                "message": "رسید فرستاده شد. پس از بررسی حسابتان شارژ می‌شود"}
#
#    def do_user_claim(self, body):
#        """Register the address the browser is coming from, for a user who is
#        already signed in - the 'my address changed' button."""
#        user = self._session_user(body.get("session"))
#        if not user:
#            return {"ok": False, "message": "نشست معتبر نیست"}
#        ip = body.get("ip", "")
#        if not valid_ip(ip):
#            return {"ok": False, "message": "آی‌پی نامعتبر"}
#        return self.do_claim_register(user["id"], ip)
#
#    def do_claim_register(self, user_id, ip):
#        owner = self.store.one("SELECT user_id FROM ips WHERE ip = ?", (ip,))
#        if owner and owner["user_id"] != user_id:
#            return {"ok": False, "message": "این آی‌پی به حساب دیگری ثبت شده است"}
#        user = self.store.one("SELECT * FROM users WHERE id = ?", (user_id,))
#        existing = self.store.user_ips(user_id)
#        # One active address per account, with as many changes as they like.
#        # Replacing rather than adding is what makes that true.
#        if existing and len(existing) >= user["max_ips"]:
#            for old in existing[: len(existing) - user["max_ips"] + 1]:
#                self.store.run("DELETE FROM ips WHERE id = ?", (old["id"],))
#        self.store.run(
#            "INSERT OR REPLACE INTO ips (user_id, ip, added_at) VALUES (?, ?, ?)",
#            (user_id, ip, now()))
#        return {"ok": True, "message": "آی‌پی %s ثبت شد" % ip}
#
#    def do_user_info(self, body):
#        user = self._session_user(body.get("session"))
#        if not user:
#            return {"ok": False, "message": "نشست معتبر نیست"}
#        ips = self.store.user_ips(user["id"])
#        tpl = self.store.one("SELECT name FROM templates WHERE id = ?",
#                             (user["template_id"],)) if user["template_id"] else None
#        if not tpl:
#            tpl = self.store.one("SELECT name FROM templates WHERE is_default = 1")
#        return {
#            "ok": True,
#            "name": user["first_name"] or user["username"] or "",
#            "telegram_id": user["telegram_id"],
#            "ip": ips[0]["ip"] if ips else None,
#            "used": user["used_bytes"],
#            "quota": user["quota_bytes"],
#            "status": user["status"],
#            "wallet": user["wallet"],
#            "plan": tpl["name"] if tpl else "",
#            "renews": (user["quota_reset_at"] or "")[:10],
#            "expires": (user["expires_at"] or "")[:10],
#            "speed_kbps": user["speed_kbps"] or 0,
#            # Which warning thresholds this account has crossed. The relay's
#            # page turns this into the banner the bot used to send.
#            "warned": user["warned"] or 0,
#            "seen_ip": body.get("ip", ""),
#        }
#
#
#def serve_api(cfg, store):
#    API.store = store
#    API.secret = cfg["SYNC_SECRET"]
#    # Comma separated, so one exit can serve several relays.
#    API.relays = tuple(x.strip() for x in cfg["RELAY_IP"].split(",") if x.strip())
#    httpd = http.server.ThreadingHTTPServer(("0.0.0.0", API_PORT), API)
#    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
#    ctx.load_cert_chain(CERT, KEY)
#    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
#    httpd.serve_forever()
#
#
#def watch_self(store):
#    """Sample this machine's own health.
#
#    The relays report theirs on the sync request, but nothing syncs *to* the
#    exit, so without this the machine running the panel would be the one host
#    missing from the panel.
#    """
#    health = Health()
#    while True:
#        try:
#            store.record_metrics("exit", health.sample())
#            store.prune_metrics()
#        except Exception as e:
#            print("self health failed: %r" % e, file=sys.stderr, flush=True)
#        time.sleep(30)
#
#
#CATALOGUE = []
## A one-element list so the API thread sees updates without a global statement.
#DEFAULT_TEMPLATE = [0]
#
#
#def main():
#    global CATALOGUE
#    cfg = load_config()
#    os.makedirs(os.path.dirname(DB), exist_ok=True)
#    store = Store(DB)
#    CATALOGUE = load_catalogue() + [CUSTOM_SERVICE]
#    DEFAULT_TEMPLATE[0] = store.ensure_default_template(CATALOGUE)["id"]
#    print("catalogue: %d services, default template #%d"
#          % (len(CATALOGUE), DEFAULT_TEMPLATE[0]), flush=True)
#
#    threading.Thread(target=watch_self, args=(store,), daemon=True).start()
#
#    def bye(*_):
#        sys.exit(0)
#
#    signal.signal(signal.SIGTERM, bye)
#    signal.signal(signal.SIGINT, bye)
#    print("panel up: api on :%d" % API_PORT, flush=True)
#    # In the foreground now. The Telegram loop used to be what kept this
#    # process alive and the API rode along on a daemon thread behind it; with
#    # the bot gone the API is the whole job, so it holds the process itself.
#    serve_api(cfg, store)
#
#
#if __name__ == "__main__":
#    main()
#__END_PANEL__

#__BEGIN_PANEL_SERVICE__
#[Unit]
#Description=Smart DNS panel - database and sync API for the relays
#After=network-online.target
#Wants=network-online.target
#
#[Service]
#Type=simple
#ExecStart=/usr/local/bin/smartdns-panel
#Restart=always
#RestartSec=10
## The bot token lives in panel.env, not in the unit and not in the script,
## because this repository is going to be public.
#EnvironmentFile=-/etc/smart-dns/panel.env
#NoNewPrivileges=yes
#ProtectSystem=strict
#ProtectHome=yes
#PrivateTmp=yes
#ReadWritePaths=/var/lib/smart-dns
#
#[Install]
#WantedBy=multi-user.target
#__END_PANEL_SERVICE__

#__BEGIN_SYNC__
##!/usr/bin/env python3
#"""smartdns-sync - the relay's half of the panel.
#
#Two jobs, one process:
#
#  * every 30 seconds, hand the exit node this relay's per-address byte
#    counters and take back who is allowed, on which resolver, at what speed
#  * serve the customer's panel - signing up, signing in, registering an
#    address, and seeing what is left of an allowance
#
#The panel has to live on the relay rather than on the exit, because the whole
#point of it is to learn the customer's address, and the only address that
#matters is the one they reach the service from. A page served in Frankfurt
#would see whatever their browser came out of.
#
#It listens outside the gated ports on purpose. The access control gate covers
#53, 80 and 443, so somebody whose address changed is cut off from the service
#but can still reach the one page that fixes it. Putting the panel on a gated
#port would have locked them out of the thing that unlocks them.
#
#The relay always dials out; nothing dials in. Standard library only.
#
#PANEL_HOST is not necessarily this relay's own exit node. The panel is a
#control plane: one database serves several relay/exit pairs, and each relay
#still carries its own traffic through its own exit.
#"""
#
#import base64
#import hashlib
#import hmac
#import html
#import http.client
#import http.cookies
#import http.server
#import json
#import os
#import ssl
#import subprocess
#import sys
#import threading
#import time
#import urllib.parse
#
#CONFIG = "/etc/smart-dns/sync.env"
#ACL = "/usr/local/bin/smartdns-acl"
#SHAPE = "/usr/local/bin/smartdns-shape"
#INTERVAL = 30
## The customer-facing panel, and the only port it is ever served on. Outside
## the gated ports (53, 80, 443) on purpose: somebody whose address changed is
## cut off from the service but must still be able to reach the one page that
## fixes it.
#PANEL_TLS_PORT = 8443
#
## A photograph of a bank slip, from a phone camera. The exit refuses anything
## past four megabytes, so there is no point carrying more than that up to it.
#MAX_RECEIPT = 4 * 1024 * 1024
#
#
#def load_config():
#    cfg = {}
#    with open(CONFIG) as fh:
#        for line in fh:
#            line = line.strip()
#            if not line or line.startswith("#") or "=" not in line:
#                continue
#            k, v = line.split("=", 1)
#            cfg[k.strip()] = v.strip().strip('"').strip("'")
#    for required in ("PANEL_HOST", "SYNC_SECRET", "SYNC_FINGERPRINT", "SELF_IP"):
#        if not cfg.get(required):
#            sys.exit("%s: %s is missing" % (CONFIG, required))
#    return cfg
#
#
#CFG = None
#
#
#def post(path, payload):
#    """POST JSON to the exit's API, pinned to its certificate.
#
#    The exit's certificate is self-signed - there is no domain on it and no CA
#    to check it against - so ordinary verification is turned off and replaced
#    with a fingerprint comparison. That is stricter than a public CA would be,
#    not weaker: exactly one certificate is accepted, and the secret is never
#    sent until it matches.
#    """
#    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
#    ctx.check_hostname = False
#    ctx.verify_mode = ssl.CERT_NONE
#    conn = http.client.HTTPSConnection(
#        CFG["PANEL_HOST"], 8443, timeout=25, context=ctx
#    )
#    try:
#        conn.connect()
#        seen = hashlib.sha256(conn.sock.getpeercert(binary_form=True)).hexdigest()
#        if not hmac.compare_digest(seen, CFG["SYNC_FINGERPRINT"].lower()):
#            raise RuntimeError(
#                "certificate fingerprint mismatch - refusing to send anything.\n"
#                "  expected %s\n  got      %s" % (CFG["SYNC_FINGERPRINT"], seen)
#            )
#        body = json.dumps(payload)
#        conn.request(
#            "POST", path, body,
#            {"Content-Type": "application/json",
#             "Authorization": "Bearer " + CFG["SYNC_SECRET"]},
#        )
#        res = conn.getresponse()
#        data = json.loads(res.read() or b"{}")
#        if res.status != 200:
#            raise RuntimeError("exit returned %d: %s" % (res.status, data))
#        return data
#    finally:
#        conn.close()
#
#
## ------------------------------------------------------------------ health
#class Health:
#    """Host metrics, read straight out of /proc.
#
#    CPU and network are rates, which means they only exist relative to a
#    previous reading - so the first sample after start reports no rate rather
#    than a meaningless one computed against zero. The sync loop runs every
#    thirty seconds, which is the interval these end up averaged over.
#    """
#
#    def __init__(self):
#        self.cpu = None
#        self.net = None
#
#    @staticmethod
#    def _meminfo():
#        out = {}
#        with open("/proc/meminfo") as fh:
#            for line in fh:
#                k, _, v = line.partition(":")
#                out[k] = int(v.split()[0]) * 1024      # kB -> bytes
#        return out
#
#    def _cpu_percent(self):
#        with open("/proc/stat") as fh:
#            parts = [int(x) for x in fh.readline().split()[1:]]
#        idle, total = parts[3] + parts[4], sum(parts)
#        prev, self.cpu = self.cpu, (idle, total)
#        if not prev:
#            return None
#        d_total = total - prev[1]
#        if d_total <= 0:
#            return None
#        return round(100.0 * (1 - (idle - prev[0]) / d_total), 1)
#
#    def _net_rates(self):
#        rx = tx = 0
#        with open("/proc/net/dev") as fh:
#            for line in fh.readlines()[2:]:
#                name, _, rest = line.partition(":")
#                if name.strip() == "lo":
#                    continue
#                f = rest.split()
#                rx += int(f[0]); tx += int(f[8])
#        now = time.time()
#        prev, self.net = self.net, (rx, tx, now)
#        if not prev:
#            return None, None
#        dt = now - prev[2]
#        if dt <= 0:
#            return None, None
#        return int((rx - prev[0]) / dt), int((tx - prev[1]) / dt)
#
#    def sample(self):
#        m = self._meminfo()
#        rx, tx = self._net_rates()
#        st = os.statvfs("/")
#        with open("/proc/uptime") as fh:
#            uptime = int(float(fh.readline().split()[0]))
#        with open("/proc/loadavg") as fh:
#            load = float(fh.readline().split()[0])
#        swap_total = m.get("SwapTotal", 0)
#        return {
#            "cpu": self._cpu_percent(),
#            "load": load,
#            "mem_total": m.get("MemTotal", 0),
#            # MemAvailable is what the kernel thinks is really obtainable, which
#            # is the number that matters; MemFree ignores reclaimable cache and
#            # makes a healthy box look nearly out of memory.
#            "mem_used": m.get("MemTotal", 0) - m.get("MemAvailable", 0),
#            # Reported as zero-total when the host has no swap, so the panel can
#            # leave the row out rather than drawing an empty gauge.
#            "swap_total": swap_total,
#            "swap_used": swap_total - m.get("SwapFree", 0) if swap_total else 0,
#            "disk_total": st.f_blocks * st.f_frsize,
#            "disk_used": (st.f_blocks - st.f_bfree) * st.f_frsize,
#            "rx_bps": rx,
#            "tx_bps": tx,
#            "uptime": uptime,
#        }
#
#
## ---------------------------------------------------------------- profiles
#PROFILE_DIR = "/etc/smartdns-profiles"
#PROFILE_BASE_PORT = 5300
#NAT_TABLE = "smartdns_nat"
#
#
#def sh(*args):
#    return subprocess.run(list(args), capture_output=True, text=True, timeout=60)
#
#
#def nft(*args):
#    return sh("/usr/sbin/nft", *args)
#
#
#CUSTOM_CONF = "/etc/dnsmasq.d/50-smartdns-custom.conf"
## The names the installer keeps out of the hijack: EA's game servers, the
## console STUN hosts, Epic's backend, core.windows.net. The main resolver
## reads this file and always will; the profiles must not, because whether
## each of those is routed is now a tick in a template, and a rule sitting in
## a shared file would outrank the tick.
#BYPASS_CONF = "/etc/dnsmasq.d/bypass.conf"
## The hijack list itself - every domain the service routes. The resolver on
## :53 reads it and always will: that one serves the default template, which
## means "everything". The profiles must not, because which of those names a
## template routes is a tick in the panel, and a rule in a file every resolver
## reads cannot be taken back by a rule in one that does not. Both would name
## the same host, dnsmasq's longest match would tie, and address= would win.
#HIJACK_CONF = "/etc/dnsmasq.d/smart-dns.conf"
## What the profile resolvers read instead of /etc/dnsmasq.d. Same files, minus
## the ones decided per template - a profile that does not route something must
## not find a rule for it at all.
#BASE_DIR = "/etc/smartdns-base"
#
#
#EPIC_PINS = "/etc/dnsmasq.d/epic-pins.conf"
#
#
#def epic_pin_lines():
#    """epic-pin's rules, to be written into the profiles that still want them.
#
#    Read rather than symlinked, because they are the one thing a profile may
#    need to be without: they name exact hosts, so they outrank any rule that
#    routes the parent domain, and a template that has chosen to route Epic's
#    backend has to be able to actually do it.
#    """
#    try:
#        with open(EPIC_PINS) as fh:
#            return [l.rstrip("\n") for l in fh
#                    if l.startswith("address=") or l.startswith("server=")]
#    except OSError:
#        return []
#
#
#def sync_base_dir():
#    """Keep BASE_DIR mirroring /etc/dnsmasq.d, minus two files.
#
#    Symlinks rather than copies, so `smartdns add` still reaches every
#    resolver on the machine without knowing this directory exists. Three files
#    are left out - the operator's own domains, epic-pin's pins, and the
#    bypass list - because each is decided per template, and absence is the
#    only mechanism that works when the rules would otherwise name the same
#    host. The panel sends every bypass this profile needs, so nothing is lost
#    by not linking the file.
#    """
#    os.makedirs(BASE_DIR, exist_ok=True)
#    want = {f for f in os.listdir("/etc/dnsmasq.d")
#            if f.endswith(".conf")
#            and f not in (os.path.basename(CUSTOM_CONF),
#                          os.path.basename(EPIC_PINS),
#                          os.path.basename(BYPASS_CONF),
#                          os.path.basename(HIJACK_CONF))}
#    have = set(os.listdir(BASE_DIR))
#    changed = False
#    for f in want - have:
#        os.symlink(os.path.join("/etc/dnsmasq.d", f), os.path.join(BASE_DIR, f))
#        changed = True
#    for f in have - want:
#        os.unlink(os.path.join(BASE_DIR, f))
#        changed = True
#    return changed
#
#
#def apply_custom_domains(domains):
#    """Route the domains the operator added in the panel.
#
#    Written into /etc/dnsmasq.d, which every resolver on this machine reads -
#    the main one and each profile - so one entry in the panel reaches every
#    plan. Returns whether anything changed, because dnsmasq cannot reload its
#    config: it has to be restarted, and restarting it on every sync would be a
#    DNS outage twice a minute.
#    """
#    self_ip = CFG.get("SELF_IP") or ""
#    body = ["# Domains added by the operator in the panel. Generated by",
#            "# smartdns-sync from the panel's database - edit it there, not here."]
#    body += ["address=/%s/%s" % (d, self_ip) for d in sorted(set(domains))]
#    text = "\n".join(body) + "\n"
#
#    current = None
#    if os.path.exists(CUSTOM_CONF):
#        with open(CUSTOM_CONF) as fh:
#            current = fh.read()
#    if current == text or (not domains and current is None):
#        return False
#
#    with open(CUSTOM_CONF, "w") as fh:
#        fh.write(text)
#    # Check before restarting. A bad line here takes DNS down for everyone on
#    # this relay, and dnsmasq refuses to start rather than skipping it.
#    if sh("/usr/sbin/dnsmasq", "--test", "-C", "/etc/dnsmasq.conf").returncode != 0:
#        if current is None:
#            os.unlink(CUSTOM_CONF)
#        else:
#            with open(CUSTOM_CONF, "w") as fh:
#                fh.write(current)
#        print("custom domains rejected by dnsmasq - reverted",
#              file=sys.stderr, flush=True)
#        return False
#    sh("systemctl", "restart", "dnsmasq")
#    print("custom domains: %d applied" % len(set(domains)), flush=True)
#    return True
#
#
#def apply_profiles(profiles, assignment, restart=False):
#    """Give each template its own resolver, and point each address at one.
#
#    dnsmasq cannot answer differently per client, so the split is done with one
#    instance per profile on its own port plus an nftables redirect keyed on the
#    source address. Customers all use the same DNS address; the kernel decides
#    which instance actually answers them.
#
#    A profile whose template routes everything gets no instance: that is what
#    the main resolver on port 53 already does, and every address not named in a
#    redirect falls through to it.
#    """
#    os.makedirs(PROFILE_DIR, exist_ok=True)
#    if sync_base_dir():
#        restart = True
#    ports = {}
#    for i, key in enumerate(sorted(profiles)):
#        ports[key] = PROFILE_BASE_PORT + i
#
#    # Read once: every profile that wants them gets the same lines.
#    epic_pins = epic_pin_lines()
#
#    wanted_units = set()
#    for key, spec in sorted(profiles.items()):
#        port = ports[key]
#        body = ["# generated by smartdns-sync - do not edit",
#                "port=%d" % port]
#        # The operator's own domains, listed only for templates that route
#        # them. They cannot be un-routed by rule the way a service can: both
#        # rules would name the same host and dnsmasq prefers the address= one.
#        # So absence is the mechanism, which is why this resolver reads
#        # BASE_DIR rather than /etc/dnsmasq.d.
#        # What this template routes, written here rather than inherited.
#        # Everything not in this list simply has no rule in this resolver, so
#        # it resolves normally and the client goes straight to it - which is
#        # what an un-ticked service is supposed to mean.
#        me = CFG.get("SELF_IP") or ""
#        body += ["address=/%s/%s" % (d, me)
#                 for d in sorted(set(spec.get("routed") or []))]
#        body += ["address=/%s/%s" % (d, me)
#                 for d in sorted(set(spec.get("custom") or []))]
#        # Names whose parent this profile routes, that it must not route
#        # itself - gosredirector.ea.com under a routed ea.com, say. Here the
#        # subtraction does work: the profile's rule names a longer host than
#        # the one hijacking the parent, so longest match prefers it.
#        body += ["server=/%s/1.1.1.1" % d for d in spec.get("bypass", [])]
#        # Epic's pins, unless this template asked to route that backend. They
#        # come last and are address= rules, so where they appear they win -
#        # which is the point: a bypass sends the name to a public resolver,
#        # while a pin sends it to an address checked to answer from here.
#        if spec.get("pins", True):
#            body += epic_pins
#        conf = os.path.join(PROFILE_DIR, "%s.conf" % key)
#        text = "\n".join(body) + "\n"
#        changed = True
#        if os.path.exists(conf):
#            with open(conf) as fh:
#                changed = fh.read() != text
#        if changed:
#            with open(conf, "w") as fh:
#                fh.write(text)
#        unit = "smartdns-dns@%s" % key
#        wanted_units.add(unit)
#        active = sh("systemctl", "is-active", unit).stdout.strip() == "active"
#        # `restart` is set when the shared /etc/dnsmasq.d changed underneath
#        # us: these instances read it too, and dnsmasq only picks up config at
#        # startup, so without this a new domain would reach the default plan
#        # and silently miss everybody on a template.
#        if changed or not active or restart:
#            sh("systemctl", "restart", unit)
#            print("profile %s on port %d (%d bypassed)"
#                  % (key, port, len(spec.get("bypass", []))), flush=True)
#
#    # Stop resolvers for profiles nobody is on any more, and delete their
#    # config, so a template an admin removed does not linger as a process.
#    running = sh("systemctl", "list-units", "--no-legend", "--plain",
#                 "smartdns-dns@*.service").stdout
#    for line in running.splitlines():
#        unit = line.split()[0].replace(".service", "") if line.split() else ""
#        if unit and unit not in wanted_units:
#            sh("systemctl", "stop", unit)
#            key = unit.split("@", 1)[1]
#            try:
#                os.remove(os.path.join(PROFILE_DIR, "%s.conf" % key))
#            except OSError:
#                pass
#            print("profile %s retired" % key, flush=True)
#
#    apply_redirects(ports, assignment)
#
#
#def apply_redirects(ports, assignment):
#    """Point each address at its profile's resolver, with one nftables set per
#    profile and a redirect rule per set."""
#    if nft("list", "table", "ip", NAT_TABLE).returncode != 0:
#        nft("add", "table", "ip", NAT_TABLE)
#    nft("add", "chain", "ip", NAT_TABLE, "pre",
#        "{ type nat hook prerouting priority dstnat ; policy accept ; }")
#    # Rebuilt from scratch each time rather than diffed: the whole chain is a
#    # handful of rules, and a rule left behind here would send a customer to
#    # the wrong resolver silently.
#    nft("flush", "chain", "ip", NAT_TABLE, "pre")
#
#    for key, port in sorted(ports.items()):
#        setname = "prof_%s" % key
#        nft("add", "set", "ip", NAT_TABLE, setname, "{ type ipv4_addr ; }")
#        nft("flush", "set", "ip", NAT_TABLE, setname)
#        members = [ip for ip, prof in assignment.items() if prof == key]
#        if members:
#            nft("add", "element", "ip", NAT_TABLE, setname,
#                "{ %s }" % ", ".join(members))
#            nft("add", "rule", "ip", NAT_TABLE, "pre",
#                "ip saddr @%s udp dport 53 redirect to :%d" % (setname, port))
#            nft("add", "rule", "ip", NAT_TABLE, "pre",
#                "ip saddr @%s tcp dport 53 redirect to :%d" % (setname, port))
#
#
#def acl(*args):
#    return subprocess.run(
#        [ACL] + list(args), capture_output=True, text=True, timeout=30
#    )
#
#
#def current_state():
#    out = acl("list", "--json")
#    if out.returncode != 0:
#        raise RuntimeError("smartdns-acl list failed: %s" % out.stderr.strip())
#    return json.loads(out.stdout or "[]")
#
#
#HEALTH = Health()
#
## What the shaper was last told. Speeds change about as often as somebody buys
## a plan, and re-running tc every thirty seconds for no reason would be thirty
## subprocesses a minute to arrive at the state already in the kernel.
#SHAPED = None
#
#
#def apply_speeds(allowed):
#    """Hand the wanted speed limits to smartdns-shape, when they have changed.
#
#    A customer with no limit is left out entirely rather than sent as zero, so
#    the shaper's job is exactly "these are the limited ones" and an account
#    going back to unlimited removes its class rather than setting it huge.
#    """
#    global SHAPED
#    wanted = sorted(
#        ({"ip": a["ip"], "mark": int(a["uid"]), "kbps": int(a.get("kbps") or 0)}
#         for a in allowed if a.get("uid") and int(a.get("kbps") or 0) > 0),
#        key=lambda w: w["mark"])
#    if wanted == SHAPED:
#        return
#    if not os.path.exists(SHAPE):
#        # An older relay that has not been upgraded yet. Say so once rather
#        # than every half minute, and carry on - unshaped is the old
#        # behaviour, not a broken one.
#        if SHAPED is None:
#            print("%s is missing - speed limits will not be applied" % SHAPE,
#                  file=sys.stderr, flush=True)
#        SHAPED = wanted
#        return
#    r = subprocess.run([SHAPE, "apply"], input=json.dumps(wanted),
#                       capture_output=True, text=True, timeout=60)
#    if r.returncode != 0:
#        # Leave SHAPED alone so the next pass tries again.
#        print("shaping failed: %s" % r.stderr.strip(), file=sys.stderr, flush=True)
#        return
#    if r.stdout.strip():
#        print(r.stdout.strip(), flush=True)
#    SHAPED = wanted
#
#
#AUTO_ENFORCE = "/etc/smart-dns/auto-enforce"
#
#
#def close_relay_when_ready(allowed_count):
#    """Switch access control on once there is somebody to allow.
#
#    The installer cannot make this call itself: a relay is installed before it
#    has a single registered address, and enforcing against an empty allowlist
#    cuts off everyone including the operator. So the installer leaves a note
#    saying what it wants, and this closes the door at the first sync that
#    brings an address.
#
#    Runs once. `smartdns-acl enforce off` deletes the note, so an operator who
#    deliberately opens the relay does not find it shut again thirty seconds
#    later.
#    """
#    if allowed_count <= 0 or not os.path.exists(AUTO_ENFORCE):
#        return
#    state = subprocess.run([ACL, "enforce", "status"], capture_output=True,
#                           text=True, timeout=30)
#    if "enforcing" in (state.stdout or ""):
#        os.unlink(AUTO_ENFORCE)      # already closed; nothing left to do
#        return
#    r = subprocess.run([ACL, "enforce", "on", "--yes"], capture_output=True,
#                       text=True, timeout=30)
#    if r.returncode != 0:
#        # Most likely the allowlist is still empty in the kernel because this
#        # is the pass that is about to fill it. Leave the note and try again
#        # on the next sync rather than reporting a problem that is not one.
#        return
#    os.unlink(AUTO_ENFORCE)
#    print("access control on: %d address(es) may use this relay"
#          % allowed_count, flush=True)
#
#
#def sync_once():
#    rows = current_state()
#    counters = {r["ip"]: r["total"] for r in rows}
#    # Metrics ride along on a request that was happening anyway - no second
#    # connection, no second schedule, and they arrive stamped with the same
#    # moment as the usage they sit beside.
#    try:
#        host = HEALTH.sample()
#    except Exception as e:
#        host = {"error": str(e)}
#    answer = post("/sync", {"counters": counters, "host": host})
#
#    names = {a["ip"]: a.get("name", "") for a in answer.get("allowed", [])}
#    want = set(names)
#    have = {r["ip"] for r in rows}
#
#    # Which resolver each address should be answered by. Applied before the
#    # allowlist below, so an address is pointed at the right resolver no later
#    # than the moment it is let in.
#    try:
#        changed = apply_custom_domains(answer.get("extra_domains") or [])
#        assignment = {a["ip"]: a.get("profile", "")
#                      for a in answer.get("allowed", []) if a.get("profile")}
#        apply_profiles(answer.get("profiles") or {}, assignment, restart=changed)
#    except Exception as e:
#        print("profiles failed: %s" % e, file=sys.stderr, flush=True)
#
#    try:
#        apply_speeds(answer.get("allowed") or [])
#    except Exception as e:
#        print("speeds failed: %s" % e, file=sys.stderr, flush=True)
#
#    for ip in sorted(want - have):
#        r = acl("add", ip, names[ip]) if names[ip] else acl("add", ip)
#        print("added %s%s" % (ip, "" if r.returncode == 0 else " FAILED: " + r.stderr.strip()),
#              flush=True)
#    for ip in sorted(have - want):
#        r = acl("del", ip)
#        print("removed %s%s" % (ip, "" if r.returncode == 0 else " FAILED: " + r.stderr.strip()),
#              flush=True)
#
#    # After the set is filled, not before: enforcing while the kernel list is
#    # still empty is refused, and would leave the relay open for another cycle.
#    close_relay_when_ready(len(want))
#    return len(want), len(want - have), len(have - want)
#
#
#def sync_loop():
#    fails = 0
#    while True:
#        try:
#            total, added, removed = sync_once()
#            if added or removed:
#                print("sync: %d allowed (+%d -%d)" % (total, added, removed), flush=True)
#            fails = 0
#        except Exception as e:
#            fails += 1
#            # Noisy for the first few, then quiet: if the exit is down for an
#            # hour the journal should not be mostly this message. The allowlist
#            # already in the kernel keeps working throughout - a sync outage
#            # must never cut off paying users.
#            if fails <= 3 or fails % 20 == 0:
#                print("sync failed (%d): %s" % (fails, e), file=sys.stderr, flush=True)
#        time.sleep(INTERVAL)
#
#
## ------------------------------------------------------------- user panel
#USER_CSS = """
#*{box-sizing:border-box}
#body{margin:0;background:#0f1115;color:#e6e8eb;
# font:15px/1.9 system-ui,'Segoe UI',Tahoma,sans-serif;
# display:flex;align-items:center;justify-content:center;min-height:100vh;padding:20px}
#.card{background:#171a21;border:1px solid #262b36;border-radius:16px;
# padding:26px;max-width:440px;width:100%}
#h1{font-size:18px;margin:0 0 4px;font-weight:600}
#.sub{color:#8b949e;font-size:13px;margin-bottom:20px}
#.row{display:flex;justify-content:space-between;align-items:baseline;
# padding:11px 0;border-bottom:1px solid #1c2029}
#.row:last-of-type{border-bottom:0}
#.k{color:#8b949e;font-size:13px}
#.v{font-weight:600}
#code{background:#0f1115;padding:3px 9px;border-radius:6px;color:#7dd3a0;font-size:14px}
#.bar{height:8px;background:#0f1115;border-radius:4px;overflow:hidden;margin-top:10px}
#.bar i{display:block;height:100%;background:#7dd3a0}
#.bar i.warn{background:#e3b341}
#.bar i.hot{background:#f85149}
#button,a.btn{display:block;width:100%;margin-top:18px;padding:13px;font:inherit;
# font-weight:600;text-align:center;text-decoration:none;
# background:#238636;color:#fff;border:0;border-radius:10px;cursor:pointer}
#button:hover,a.btn:hover{background:#2ea043}
#button.ghost,a.btn.ghost{background:transparent;border:1px solid #30363d;
# color:#9aa4b2;font-weight:400}
#button.ghost:hover,a.btn.ghost:hover{background:#1c2029}
#label{display:block;color:#8b949e;font-size:12px;margin:14px 0 6px}
#input{width:100%;padding:12px;font:inherit;background:#0f1115;color:#e6e8eb;
# border:1px solid #30363d;border-radius:10px}
#input:focus{outline:0;border-color:#238636}
#.alt{text-align:center;margin-top:18px;font-size:13px;color:#8b949e}
#.alt a{color:#7dd3a0}
#.big{font-size:22px;font-weight:600;text-align:center;letter-spacing:.5px;
# background:#0f1115;border:1px solid #262b36;border-radius:12px;padding:18px;
# color:#7dd3a0;margin:6px 0 4px;direction:ltr}
#.note{color:#8b949e;font-size:12px;line-height:1.8;margin-top:16px}
#.msg{padding:11px 14px;border-radius:9px;margin-bottom:16px;font-size:13px}
#.msg.good{background:#12261a;border:1px solid #238636}
#.msg.err{background:#2b1416;border:1px solid #6e2c2c}
#.msg.warnbox{background:#2b2411;border:1px solid #6e5a2c}
#.icon{font-size:40px;text-align:center;line-height:1;margin-bottom:12px}
#.dns{margin-top:20px;padding:16px;background:#0f1115;border:1px solid #262b36;
# border-radius:12px}
#.dns .k{color:#8b949e;font-size:12px;margin-bottom:8px}
#.dns .big{margin:0}
#.dns .note{margin-top:12px}
#.dns input[type=file]{width:100%;padding:10px;font-size:12px;
# border:1px dashed #30363d;background:transparent;margin-bottom:4px}
#details.pw{margin-top:16px;border:1px solid #262b36;border-radius:12px;
# background:#0f1115}
#details.pw>summary{padding:14px 16px;cursor:pointer;color:#9aa4b2;font-size:13px;
# list-style:none}
#details.pw>summary::-webkit-details-marker{display:none}
#details.pw>summary::before{content:'b8';margin-left:8px;font-size:11px}
#details.pw[open]>summary::before{content:'be'}
#details.pw form{padding:0 16px 4px}
#details.pw .note{padding:0 16px 14px;margin-top:8px}
#.ok{color:#7dd3a0}.bad{color:#f85149}.warn{color:#e3b341}
#"""
#
#
#def brand():
#    """What to call the service on the customer's pages.
#
#    The domain they typed to get here. Nothing to configure, nothing that can
#    disagree with the address in the browser bar, and no second place to
#    rename the service and forget.
#    """
#    return (CFG or {}).get("PANEL_DOMAIN") or "سرویس"
#
#
#def user_page(inner):
#    return ("""<!doctype html><html lang="fa" dir="rtl"><head><meta charset="utf-8">
#<meta name="viewport" content="width=device-width,initial-scale=1">
#<title>%s</title><style>%s</style></head><body>
#<div class="card">%s</div></body></html>"""
#            % (html.escape(brand()), USER_CSS, inner))
#
#
#def landing(banner=""):
#    return (banner +
#            "<div class='icon'>🌐</div><h1>%s</h1>"
#            "<p class='sub'>برای دیدن حساب و ثبت آی‌پی وارد شوید.</p>"
#            "<a class='btn' href='/login'>ورود</a>"
#            "<a class='btn ghost' href='/signup'>ثبت‌نام</a>"
#            "<p class='note'>از همان اینترنتی وارد شوید که می‌خواهید سرویس "
#            "روی آن کار کند — آی‌پی همان اتصال ثبت می‌شود.</p>"
#            % html.escape(brand()))
#
#
#def signup_form(banner=""):
#    return (banner +
#            "<h1>ثبت‌نام</h1><p class='sub'>%s</p>"
#            "<form method='post' action='/signup'>"
#            "<label>نام</label>"
#            "<input name='name' maxlength='60' autocomplete='name'>"
#            "<label>نام کاربری</label>"
#            "<input name='username' required minlength='3' maxlength='32' "
#            "pattern='[A-Za-z0-9._-]{3,32}' placeholder='ali_reza' "
#            "autocapitalize='none' spellcheck='false' "
#            "autocomplete='username'>"
#            "<label>رمز عبور (دست‌کم ۸ نویسه)</label>"
#            "<input name='password' type='password' required minlength='8' "
#            "autocomplete='new-password'>"
#            "<label>تکرار رمز عبور</label>"
#            "<input name='password2' type='password' required minlength='8' "
#            "autocomplete='new-password'>"
#            "<button>ساخت حساب</button></form>"
#            "<p class='note'>نام کاربری همان چیزی است که با آن وارد می‌شوید — "
#            "حروف انگلیسی، عدد، و . _ - ؛ بزرگ و کوچک فرقی ندارد. اگر قبلاً "
#            "کسی گرفته باشدش، پیغام می‌دهد.</p>"
#            "<p class='alt'>حساب دارید؟ <a href='/login'>وارد شوید</a></p>"
#            % html.escape(brand()))
#
#
#def login_form(banner=""):
#    return (banner +
#            "<h1>ورود</h1><p class='sub'>%s</p>"
#            "<form method='post' action='/login'>"
#            "<label>نام کاربری</label>"
#            "<input name='username' required maxlength='32' "
#            "autocapitalize='none' spellcheck='false' "
#            "autocomplete='username'>"
#            "<label>رمز عبور</label>"
#            "<input name='password' type='password' required "
#            "autocomplete='current-password'>"
#            "<button>ورود</button></form>"
#            "<p class='alt'>حساب ندارید؟ <a href='/signup'>ثبت‌نام کنید</a></p>"
#            % html.escape(brand()))
#
#
#def register_ip_page(ip, banner=""):
#    """The step between signing up and having a working service.
#
#    It shows the address rather than registering it quietly, because this is
#    the one thing on the whole panel the customer has to get right: the address
#    seen here is the address that will work, and if they opened the page over
#    mobile data or a VPN it is the wrong one. Naming it gives them the chance
#    to notice.
#    """
#    return (banner +
#            "<div class='icon'>📍</div><h1>ثبت آی‌پی</h1>"
#            "<p class='sub'>سرویس روی همین آی‌پی باز می‌شود.</p>"
#            "<div class='big'>%s</div>"
#            "<form method='post' action='/register-ip'>"
#            "<button>همین آی‌پی را ثبت کن</button></form>"
#            "<p class='note'>اگر این آی‌پی اینترنت خانه یا موبایل شما "
#            "<b>نیست</b> — مثلاً وی‌پی‌ان روشن است یا از اینترنت دیگری وارد "
#            "شده‌اید — آن را ببندید، همین صفحه را تازه کنید و بعد ثبت کنید.</p>"
#            "<p class='note'>آی‌پی خانگی معمولاً ثابت نیست. اگر مودم را ریست "
#            "کردید و سرویس قطع شد، دوباره به همین صفحه بیایید و ثبت کنید.</p>"
#            "<p class='alt'><a href='/'>فعلاً نه، برو به حساب</a></p>"
#            % html.escape(ip))
#
#
#def account_notice(info):
#    """The warning the bot used to send, on the page instead.
#
#    A message reached only the accounts that had a Telegram behind them, which
#    by the end was a minority. This reaches everybody, and it is on the screen
#    they open when something has stopped working - which is when they look.
#
#    Only the worst applicable one is shown. Three stacked warnings about the
#    same allowance is noise, and the reader stops reading.
#    """
#    status = info.get("status")
#    # First thing a new customer sees, so it says what to do rather than what
#    # is wrong. Nothing is wrong: they have an account, and it is waiting.
#    if status == "pending":
#        return ("<div class='msg warnbox'><b>حساب شما ساخته شد.</b> "
#                "برای فعال شدن سرویس، رسید پرداختتان را از پایین همین صفحه "
#                "بفرستید — بعد از تأیید، پلن برایتان ثبت می‌شود.</div>")
#    if status == "expired":
#        return ("<div class='msg err'><b>دورهٔ شما تمام شد.</b> "
#                "سرویس تا تمدید کار نمی‌کند.</div>")
#    if status == "over_quota":
#        return ("<div class='msg err'><b>سهمیهٔ شما تمام شد.</b> "
#                "سرویس تا شارژ مجدد قطع است.</div>")
#    if status != "active":
#        return "<div class='msg err'>حساب شما غیرفعال است.</div>"
#
#    quota, used = info.get("quota") or 0, info.get("used") or 0
#    if quota:
#        left = max(0, quota - used)
#        # The same thresholds the panel records, read back rather than
#        # recomputed, so the page and the database never disagree about
#        # whether somebody has been warned.
#        if info.get("warned", 0) & 2:
#            return ("<div class='msg err'>بیش از ۹۵٪ سهمیه‌تان مصرف شده — "
#                    "%s مانده.</div>" % human_fa(left))
#        if info.get("warned", 0) & 1:
#            return ("<div class='msg warnbox'>بیش از ۸۰٪ سهمیه‌تان مصرف شده — "
#                    "%s مانده.</div>" % human_fa(left))
#
#    ends = info.get("expires")
#    if ends:
#        return ("<div class='msg warnbox'>دورهٔ شما در <b>%s</b> "
#                "تمام می‌شود.</div>" % html.escape(ends))
#    return ""
#
#
#def dns_box():
#    """The address the customer has to type into their console or router.
#
#    Served by the relay, so it is this machine's own address - not something
#    configured twice and able to disagree. A customer on a second relay is
#    looking at that relay's page and gets that relay's address, which is the
#    one that will work for them.
#
#    Only the first is given. Consoles ask for two, and the honest answer is to
#    repeat this one: a second, different resolver would answer the sanctioned
#    names truthfully and the service would fail intermittently in a way nobody
#    could diagnose.
#    """
#    ip = (CFG or {}).get("SELF_IP", "")
#    if not ip:
#        return ""
#    return ("<div class='dns'><div class='k'>آدرس DNS</div>"
#            "<div class='big'>%s</div>"
#            "<p class='note'>این را در تنظیمات شبکهٔ کنسول، گوشی یا مودم "
#            "به‌عنوان <b>DNS اول</b> بگذارید. اگر DNS دوم هم می‌خواهد، "
#            "<b>همین آدرس</b> را دوباره بنویسید — آدرس دیگری آنجا باعث می‌شود "
#            "سرویس گاهی کار کند و گاهی نه.</p></div>" % html.escape(ip))
#
#
#def human_fa(n):
#    n = float(n or 0)
#    for unit in ("بایت", "کیلوبایت", "مگابایت", "گیگابایت", "ترابایت"):
#        if n < 1024 or unit == "ترابایت":
#            return ("%d %s" if unit == "بایت" else "%.2f %s") % (n, unit)
#        n /= 1024
#
#
#class UserPanel(http.server.BaseHTTPRequestHandler):
#    """The page a customer sees.
#
#    It keeps no state of its own. The cookie is handed to the panel on the exit
#    node, which says who it belongs to - so a relay rebuilt from scratch does
#    not log anybody out, and a second relay serves the same session without the
#    two needing to share anything.
#    """
#
#    server_version = "smartdns"
#    protocol_version = "HTTP/1.1"
#
#    def log_message(self, *a):
#        pass
#
#    def client_ip(self):
#        # The socket, never a header. Trusting X-Forwarded-For here would let
#        # anyone register any address by sending one.
#        return self.client_address[0]
#
#    def send_html(self, body, code=200, headers=None):
#        blob = user_page(body).encode("utf-8")
#        # See send(): a clean buffer, so a failed attempt cannot leave half a
#        # status line in front of this one.
#        self._headers_buffer = []
#        self.send_response(code)
#        self.send_header("Content-Type", "text/html; charset=utf-8")
#        self.send_header("Content-Length", str(len(blob)))
#        self.send_header("Cache-Control", "no-store")
#        self.send_header("X-Frame-Options", "DENY")
#        self.send_header("X-Content-Type-Options", "nosniff")
#        for k, v in (headers or {}).items():
#            self.send_header(k, v)
#        self.end_headers()
#        self.wfile.write(blob)
#
#    def session(self):
#        cookie = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
#        return cookie["sdu"].value if "sdu" in cookie else ""
#
#    def upload(self, field):
#        """Pull one file out of a multipart body: (bytes, content type).
#
#        Hand-written because cgi was removed in Python 3.13 and this installer
#        has no pip step. One field is all that is needed, so this only has to
#        find its part and hand back what sits between the blank line and the
#        next boundary.
#        """
#        ctype = self.headers.get("Content-Type") or ""
#        if "boundary=" not in ctype:
#            raise ValueError("فایلی فرستاده نشد")
#        boundary = ctype.split("boundary=", 1)[1].strip().strip('"')
#        want = ('name="%s"' % field).encode("latin-1")
#        for part in getattr(self, "raw_body", b"").split(b"--" + boundary.encode("latin-1")):
#            head, blank, data = part.partition(b"\r\n\r\n")
#            if not blank or want not in head:
#                continue
#            kind = ""
#            for line in head.split(b"\r\n"):
#                if line.lower().startswith(b"content-type:"):
#                    kind = line.split(b":", 1)[1].decode("latin-1").strip()
#            # The trailing CRLF belongs to the delimiter, not the file.
#            return (data[:-2] if data.endswith(b"\r\n") else data), kind
#        raise ValueError("فایلی انتخاب نشده بود")
#
#    def form(self):
#        """Read the POST body. Bounded, because this is a public port in Iran
#        and nothing stops somebody announcing a gigabyte.
#
#        A receipt arrives as multipart and is kept as raw bytes for upload()
#        to pick apart; everything else is a small urlencoded form.
#        """
#        try:
#            length = int(self.headers.get("Content-Length") or 0)
#        except ValueError:
#            return {}
#        if length <= 0:
#            return {}
#        if "multipart/form-data" in (self.headers.get("Content-Type") or ""):
#            if length > MAX_RECEIPT + 64 * 1024:      # the file plus its wrapper
#                self.raw_body = b""
#                return {"too_big": "1"}
#            self.raw_body = self.rfile.read(length)
#            return {}
#        if length > 8192:
#            return {}
#        raw = self.rfile.read(length).decode("utf-8", "replace")
#        return {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}
#
#    def cookie_for(self, session):
#        return ("sdu=%s; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=%d"
#                % (session, 30 * 86400))
#
#    def redirect(self, where, message="", bad=False):
#        if message:
#            where += ("&" if "?" in where else "?") + "m=" + \
#                urllib.parse.quote(message) + ("&e=1" if bad else "")
#        return self.send("", 303, {"Location": where})
#
#    def banner(self):
#        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
#        msg = (q.get("m") or [""])[0]
#        if not msg:
#            return ""
#        return "<div class='msg %s'>%s</div>" % (
#            "err" if q.get("e") else "good", html.escape(msg[:200]))
#
#    def do_GET(self):
#        path = urllib.parse.urlparse(self.path).path.rstrip("/") or "/"
#
#        if path in ("/signup", "/login"):
#            # Whether a cookie is here decides only whether to offer a way back
#            # to the account, never whether to show the form. Bouncing on the
#            # cookie's mere existence trapped anyone holding an expired one:
#            # they were sent to a page that said their session had ended, on
#            # their way to the page that would have given them a new one.
#            back = ("<p class='alt'><a href='/'>برگشت به حساب</a></p>"
#                    if self.session() else "")
#            return self.send_html(
#                (signup_form(self.banner()) if path == "/signup"
#                 else login_form(self.banner())) + back)
#
#        if path == "/register-ip":
#            if not self.session():
#                return self.redirect("/")
#            return self.send_html(register_ip_page(self.client_ip(), self.banner()))
#
#        if path == "/logout":
#            return self.send("", 303, {"Location": "/",
#                                       "Set-Cookie": "sdu=; Path=/; Max-Age=0"})
#
#        if path != "/":
#            return self.send_html("<div class='icon'>❔</div><h1>صفحه پیدا نشد</h1>", 404)
#        return self.dashboard()
#
#    def send(self, body, code, headers):
#        blob = body.encode() if isinstance(body, str) else body
#        # Nothing reaches the socket until end_headers(), so a send() that
#        # raised part-way through leaves a half-written status line behind.
#        # Clearing the buffer keeps the next response from being appended to
#        # it and handed to the browser as one corrupt reply.
#        self._headers_buffer = []
#        self.send_response(code)
#        self.send_header("Content-Length", str(len(blob)))
#        for k, v in headers.items():
#            self.send_header(k, v)
#        self.end_headers()
#        self.wfile.write(blob)
#
#    def do_POST(self):
#        path = urllib.parse.urlparse(self.path).path.rstrip("/") or "/"
#
#        if path in ("/signup", "/login"):
#            form = self.form()
#            endpoint = "/user-signup" if path == "/signup" else "/user-password-login"
#            payload = {"username": form.get("username", ""),
#                       "password": form.get("password", ""),
#                       "ip": self.client_ip()}
#            if path == "/signup":
#                payload["name"] = form.get("name", "")
#                if form.get("password") != form.get("password2"):
#                    return self.redirect("/signup", "دو رمز یکی نیستند", bad=True)
#            try:
#                res = post(endpoint, payload)
#            except Exception as e:
#                print("%s failed: %s" % (endpoint, e), file=sys.stderr, flush=True)
#                return self.redirect(path, "الان نشد، چند دقیقه دیگر", bad=True)
#            if not res.get("ok"):
#                return self.redirect(path, res.get("message", "خطا"), bad=True)
#            # Straight to the address page either way. A new account has no
#            # address yet, and somebody signing in from a new connection is
#            # usually signing in precisely because the address changed.
#            return self.send("", 303, {
#                "Location": "/register-ip",
#                "Set-Cookie": self.cookie_for(res["session"])})
#
#        if path == "/password":
#            if not self.session():
#                return self.redirect("/")
#            form = self.form()
#            if form.get("new") != form.get("again"):
#                return self.redirect("/", "دو رمز تازه یکی نیستند", bad=True)
#            try:
#                res = post("/user-password", {
#                    "session": self.session(),
#                    "current": form.get("current", ""),
#                    "new": form.get("new", ""),
#                })
#            except Exception as e:
#                print("password change failed: %s" % e, file=sys.stderr, flush=True)
#                return self.redirect("/", "الان نشد، چند دقیقه دیگر", bad=True)
#            return self.redirect("/", res.get("message", ""),
#                                 bad=not res.get("ok"))
#
#        if path == "/receipt":
#            if not self.session():
#                return self.redirect("/")
#            form = self.form()
#            if form.get("too_big"):
#                return self.redirect("/", "فایل خیلی بزرگ است", bad=True)
#            try:
#                blob, kind = self.upload("file")
#            except ValueError as e:
#                return self.redirect("/", str(e), bad=True)
#            try:
#                res = post("/user-receipt", {
#                    "session": self.session(),
#                    "content_type": kind,
#                    "data": base64.b64encode(blob).decode("ascii"),
#                })
#            except Exception as e:
#                print("receipt failed: %s" % e, file=sys.stderr, flush=True)
#                return self.redirect("/", "الان نشد، چند دقیقه دیگر", bad=True)
#            return self.redirect("/", res.get("message", ""),
#                                 bad=not res.get("ok"))
#
#        if path != "/register-ip":
#            return self.send_html("<h1>404</h1>", 404)
#        try:
#            res = post("/user-claim", {"session": self.session(),
#                                       "ip": self.client_ip()})
#        except Exception:
#            res = {"ok": False, "message": "الان نشد"}
#        return self.redirect("/", res.get("message", ""), bad=not res.get("ok"))
#
#    def dashboard(self):
#        token = self.session()
#        if not token:
#            return self.send_html(landing(self.banner()))
#        try:
#            info = post("/user-info", {"session": token, "ip": self.client_ip()})
#        except Exception as e:
#            print("user-info failed: %s" % e, file=sys.stderr, flush=True)
#            return self.send_html("<div class='icon'>⚠️</div><h1>الان نشد</h1>"
#                                  "<p class='sub'>چند دقیقه دیگر دوباره.</p>", 502)
#        if not info.get("ok"):
#            return self.send_html(
#                "<div class='icon'>🔑</div><h1>نشست منقضی شده</h1>"
#                "<p class='sub'>دوباره <a href='/login'>وارد شوید</a>.</p>",
#                200, {"Set-Cookie": "sdu=; Path=/; Max-Age=0"})
#
#        banner = self.banner()
#
#        used, quota = info["used"], info["quota"]
#        seen = info.get("seen_ip") or self.client_ip()
#        rows = [("پلن", html.escape(info.get("plan") or "-")),
#                ("آی‌پی ثبت‌شده", "<code>%s</code>" % html.escape(info["ip"] or "ثبت نشده")),
#                ("مصرف", human_fa(used))]
#        if quota:
#            rows.append(("سهمیه", human_fa(quota)))
#            rows.append(("باقی‌مانده", human_fa(max(0, quota - used))))
#        else:
#            rows.append(("سهمیه", "نامحدود"))
#        kbps = info.get("speed_kbps") or 0
#        rows.append(("سرعت", ("%g مگابیت بر ثانیه" % (kbps / 1000.0)) if kbps
#                     else "بدون محدودیت"))
#        if info.get("expires"):
#            rows.append(("پایان دوره", info["expires"]))
#        elif info.get("renews"):
#            rows.append(("تمدید", info["renews"]))
#        rows.append(("کیف پول", "%s تومان" % format(info.get("wallet") or 0, ",")))
#        state = {"active": "<span class='ok'>فعال</span>",
#                 "pending": "<span class='warn'>در انتظار فعال‌سازی</span>",
#                 "over_quota": "<span class='warn'>سهمیه تمام شده</span>",
#                 "expired": "<span class='warn'>دورهٔ شما تمام شد</span>"}.get(
#                     info["status"], "<span class='bad'>غیرفعال</span>")
#        rows.append(("وضعیت", state))
#
#        gauge = ""
#        if quota:
#            pct = min(100, int(100.0 * used / quota))
#            cls = "hot" if pct >= 90 else ("warn" if pct >= 75 else "")
#            gauge = ("<div class='bar'><i class='%s' style='width:%d%%'></i></div>"
#                     % (cls, pct))
#
#        body = ["<h1>%s</h1>" % html.escape(info.get("name") or "حساب شما"),
#                "<div class='sub'>%s</div>" % html.escape(brand()),
#                banner, account_notice(info)]
#        for k, v in rows:
#            body.append("<div class='row'><span class='k'>%s</span>"
#                        "<span class='v'>%s</span></div>" % (k, v))
#        body.append(gauge)
#        body.append(dns_box())
#
#        if not info["ip"]:
#            body.append(
#                "<a class='btn' href='/register-ip'>ثبت آی‌پی — سرویس هنوز "
#                "باز نشده</a>"
#                "<p class='note'>تا آی‌پی ثبت نشود سرویس روی اینترنت شما کار "
#                "نمی‌کند.</p>")
#        elif info["ip"] != seen:
#            body.append(
#                "<a class='btn' href='/register-ip'>ثبت آی‌پی فعلی (%s)</a>"
#                "<p class='note'>آی‌پی اینترنت شما با آنچه ثبت شده فرق دارد. "
#                "این دکمه آی‌پی فعلی را جایگزین می‌کند.</p>" % html.escape(seen))
#        else:
#            body.append(
#                "<a class='btn ghost' href='/register-ip'>"
#                "ثبت دوباره همین آی‌پی</a>"
#                "<p class='note'>آی‌پی شما درست ثبت شده. اگر مودم را ریست کردید و "
#                "سرویس قطع شد، همین صفحه را باز کنید و این دکمه را بزنید.</p>")
#        body.append(
#            "<div class='dns'><div class='k'>ارسال رسید پرداخت</div>"
#            "<p class='note' style='margin-top:0'>عکس فیش واریزی را بفرستید تا "
#            "مدیر بررسی کند و حسابتان شارژ شود. عکس یا PDF، حداکثر ۴ مگابایت. "
#            "اگر رسید تازه‌ای بفرستید، جای قبلی را می‌گیرد.</p>"
#            "<form method='post' action='/receipt' enctype='multipart/form-data'>"
#            "<input type='file' name='file' required "
#            "accept='image/jpeg,image/png,image/webp,application/pdf'>"
#            "<button class='ghost'>فرستادن رسید</button></form></div>")
#        body.append(
#            "<details class='pw'><summary>تغییر رمز عبور</summary>"
#            "<form method='post' action='/password'>"
#            "<label>رمز فعلی</label>"
#            "<input name='current' type='password' required "
#            "autocomplete='current-password'>"
#            "<label>رمز تازه (دست‌کم ۸ نویسه)</label>"
#            "<input name='new' type='password' required minlength='8' "
#            "autocomplete='new-password'>"
#            "<label>تکرار رمز تازه</label>"
#            "<input name='again' type='password' required minlength='8' "
#            "autocomplete='new-password'>"
#            "<button class='ghost'>تغییر رمز</button></form>"
#            "<p class='note'>اگر جای دیگری وارد حسابتان باشید، با تغییر رمز "
#            "از آنجا خارج می‌شوید.</p></details>")
#        body.append("<p class='alt'><a href='/logout'>خروج از حساب</a></p>")
#        return self.send_html("".join(body))
#
#
#def main():
#    global CFG
#    CFG = load_config()
#    if not os.path.exists(ACL):
#        sys.exit("%s is missing - run the installer first" % ACL)
#    threading.Thread(target=sync_loop, daemon=True).start()
#
#    # Over TLS or not at all. This panel asks for a password and hands back a
#    # session cookie, and there is no version of that which is safe over plain
#    # http on an Iranian ISP. There used to be a second, plain listener that
#    # served a page explaining why the forms were switched off; a port that
#    # serves anything is a port that can be pointed at, so it is gone rather
#    # than harmless.
#    if CFG.get("PANEL_DOMAIN"):
#        serve_panel()
#    else:
#        print("sync up: every %ds to %s - no certificate, so no customer panel"
#              % (INTERVAL, CFG["PANEL_HOST"]), flush=True)
#        while True:
#            time.sleep(3600)
#
#
## How long a visitor may take to finish the TLS handshake, and then how long
## any one read or write may stall once it has. Per operation, not in total: a
## receipt crawling up a slow mobile link keeps making progress and is never
## cut off, while a connection that has simply gone quiet is let go.
#HANDSHAKE_TIMEOUT = 10
#IO_TIMEOUT = 30
#
#
#class PanelServer(http.server.ThreadingHTTPServer):
#    """The customer panel's server, with TLS done per connection.
#
#    It used to wrap the listening socket. That puts every visitor's TLS
#    handshake inside accept(), on the single thread that accepts for all of
#    them, with no timeout - so one phone whose connection dropped half way
#    through a handshake froze the panel for everybody until it went away,
#    which without a timeout could be never. On mobile networks in Iran that is
#    an ordinary event, and it was reported as "I sent my receipt and the page
#    stopped loading".
#
#    Here accept() only ever does accept(). The handshake happens in the
#    connection's own thread, under a deadline, so a stalled visitor stalls
#    only itself.
#    """
#    daemon_threads = True
#
#    def __init__(self, addr, handler, ctx):
#        self.ctx = ctx
#        super().__init__(addr, handler)
#
#    def finish_request(self, request, client_address):
#        request.settimeout(HANDSHAKE_TIMEOUT)
#        try:
#            tls = self.ctx.wrap_socket(request, server_side=True)
#        except (ssl.SSLError, OSError):
#            # A scanner, a dropped phone, somebody speaking plain http to an
#            # https port. Nothing to answer, and nobody else is kept waiting.
#            return
#        try:
#            tls.settimeout(IO_TIMEOUT)
#            self.RequestHandlerClass(tls, client_address, self)
#        except (ssl.SSLError, OSError):
#            pass
#        finally:
#            try:
#                tls.close()
#            except OSError:
#                pass
#
#
#def make_panel_server(ctx, port=None):
#    return PanelServer(("0.0.0.0", PANEL_TLS_PORT if port is None else port),
#                       UserPanel, ctx)
#
#
#def serve_panel():
#    cert = "/etc/letsencrypt/live/%s/fullchain.pem" % CFG["PANEL_DOMAIN"]
#    key = "/etc/letsencrypt/live/%s/privkey.pem" % CFG["PANEL_DOMAIN"]
#    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
#    ctx.load_cert_chain(cert, key)
#    httpd = make_panel_server(ctx)
#    print("sync up: every %ds to %s, panel on https://%s:%d/"
#          % (INTERVAL, CFG["PANEL_HOST"], CFG["PANEL_DOMAIN"], PANEL_TLS_PORT),
#          flush=True)
#    httpd.serve_forever()
#
#
#if __name__ == "__main__":
#    main()
#__END_SYNC__

#__BEGIN_SYNC_SERVICE__
#[Unit]
#Description=Smart DNS relay sync - usage out, allowlist in, claim page
#After=network-online.target nftables.service
#Wants=network-online.target
#
#[Service]
#Type=simple
#ExecStart=/usr/local/bin/smartdns-sync
#Restart=always
#RestartSec=10
## Needs root: it drives smartdns-acl, which talks to nftables.
#NoNewPrivileges=yes
#ProtectHome=yes
#PrivateTmp=yes
#
#[Install]
#WantedBy=multi-user.target
#__END_SYNC_SERVICE__

#__BEGIN_DNS_PROFILE_UNIT__
#[Unit]
#Description=Smart DNS resolver for service template %i
#After=network-online.target
#PartOf=smartdns-sync.service
#
#[Service]
#Type=simple
## /etc/smartdns-base mirrors /etc/dnsmasq.d by symlink, minus the operator's
## custom domains. Sharing by symlink means `smartdns add` and epic-pin still
## reach every resolver; leaving the custom file out is what lets a template
## not route those domains, since they cannot be un-routed by rule.
#ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=/dev/null \
#    --conf-dir=/etc/smartdns-base --conf-file=/etc/smartdns-profiles/%i.conf
#Restart=always
#RestartSec=5
#
#[Install]
#WantedBy=multi-user.target
#__END_DNS_PROFILE_UNIT__

#__BEGIN_CERT__
##!/bin/bash
## smartdns-cert - obtain and renew the panel's TLS certificate.
##
## usage: smartdns-cert <domain>        get or renew a certificate
##        smartdns-cert --renew         renew everything due (the timer's job)
##
## Port 80 is the problem this script exists to work around. Let's Encrypt's
## HTTP-01 challenge needs it, and on a relay port 80 is forwarded whole to the
## exit node so that console downloads work: Sony and Microsoft serve game
## packages over plain HTTP from Akamai edges that answer 443 with a certificate
## naming no console host at all. Rebuilding nginx to terminate HTTP and answer
## the challenge itself would put an L7 proxy in the middle of the exact path
## that took a week to get right.
##
## So nginx is not touched. For the twenty seconds a challenge takes, an
## nftables rule sends port 80 to a local certbot instead, and the rule is
## removed afterwards - including when certbot fails, which is what the trap is
## for. A leftover rule would send every console download into a dead port.
##
## The cost is honest: console HTTP downloads stall for those twenty seconds, on
## the day a certificate is issued and again every sixty days. A download that
## stalls resumes; a certificate that expires takes the panel down until someone
## notices.
##
## If /etc/smart-dns/cloudflare.ini exists, DNS-01 is used instead and port 80
## is never touched at all. Nothing here asks for that token - it is only used
## when the operator has deliberately put it there.
#set -uo pipefail
#export PATH="$PATH:/usr/sbin:/sbin"
#
#CF_CONF=/etc/smart-dns/cloudflare.ini
#LIVE=/etc/letsencrypt/live
#ACME_PORT=8402
#NAT_TABLE=smartdns_acme
#
#R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'
#[ -t 1 ] || { R=; G=; Y=; N=; }
#die() { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
#
#[ "$(id -u)" = 0 ] || die "run as root"
#
#open_port80() {
#    nft add table ip $NAT_TABLE 2>/dev/null
#    nft add chain ip $NAT_TABLE pre \
#        '{ type nat hook prerouting priority dstnat ; policy accept ; }' 2>/dev/null
#    nft add rule ip $NAT_TABLE pre tcp dport 80 redirect to :$ACME_PORT
#}
#
#close_port80() {
#    nft delete table ip $NAT_TABLE 2>/dev/null
#    return 0
#}
#
#issue() {
#    local domain="$1"
#    if [ -f "$CF_CONF" ]; then
#        # The operator supplied a DNS token, so prove it that way and leave
#        # port 80 alone entirely.
#        certbot certonly --dns-cloudflare \
#            --dns-cloudflare-credentials "$CF_CONF" \
#            --dns-cloudflare-propagation-seconds 30 \
#            --register-unsafely-without-email --agree-tos \
#            --non-interactive --quiet --cert-name "$domain" -d "$domain"
#        return $?
#    fi
#
#    # Always put port 80 back, whatever happens next.
#    trap close_port80 EXIT INT TERM
#    open_port80 || die "could not redirect port 80 for the challenge"
#    certbot certonly --standalone --http-01-port "$ACME_PORT" \
#        --register-unsafely-without-email --agree-tos \
#        --non-interactive --quiet --cert-name "$domain" -d "$domain"
#    local rc=$?
#    close_port80
#    trap - EXIT INT TERM
#    return $rc
#}
#
#case "${1:-}" in
#--renew)
#    # certbot decides what is due, so almost every run does nothing. The
#    # redirect is only opened when something actually needs renewing.
#    if certbot renew --dry-run >/dev/null 2>&1 || true; then :; fi
#    for path in "$LIVE"/*/; do
#        [ -d "$path" ] || continue
#        domain="$(basename "$path")"
#        openssl x509 -checkend $((30 * 86400)) -noout \
#            -in "$path/fullchain.pem" >/dev/null 2>&1 && continue
#        printf 'renewing %s\n' "$domain"
#        issue "$domain" && systemctl reload nginx 2>/dev/null
#    done
#    exit 0
#    ;;
#"")
#    die "usage: smartdns-cert <domain>" ;;
#esac
#
#DOMAIN="$1"
#
## A machine installed without a domain has this script but not certbot - the
## installer only pulls certbot in when it is about to issue something. Since
## the whole point of running this later is that there was no domain at install
## time, "certbot: not found" is the most likely first thing anybody sees here.
#if ! command -v certbot >/dev/null 2>&1; then
#    printf '    installing certbot\n'
#    export DEBIAN_FRONTEND=noninteractive
#    pkgs=certbot
#    [ -f "$CF_CONF" ] && pkgs="$pkgs python3-certbot-dns-cloudflare"
#    apt-get update -qq >/dev/null 2>&1
#    # shellcheck disable=SC2086
#    apt-get install -y -qq $pkgs >/dev/null 2>&1 \
#        || die "could not install certbot:  apt-get install -y $pkgs"
#fi
#
## Already have one with plenty of life left? Do nothing. Let's Encrypt limits
## issuance per domain per week, and re-issuing on every installer run would
## burn that allowance and then fail at the moment it mattered.
#if [ -d "$LIVE/$DOMAIN" ] && openssl x509 -checkend $((30 * 86400)) -noout \
#        -in "$LIVE/$DOMAIN/fullchain.pem" >/dev/null 2>&1; then
#    printf '    certificate for %s is current\n' "$DOMAIN"
#    exit 0
#fi
#
#if [ ! -f "$CF_CONF" ]; then
#    printf '    %sopening port 80 for about twenty seconds%s - console downloads\n' "$Y" "$N"
#    printf '    through this machine will stall until the challenge finishes\n'
#fi
#printf '    getting a certificate for %s\n' "$DOMAIN"
#issue "$DOMAIN" || die "certbot could not get a certificate for $DOMAIN.
#    The name must point at this machine and port 80 must be reachable from the
#    internet - that is how Let's Encrypt checks you control it."
#
#printf '%s    certificate installed:%s %s\n' "$G" "$N" "$LIVE/$DOMAIN/fullchain.pem"
#__END_CERT__

#__BEGIN_CERT_SERVICE__
#[Unit]
#Description=Renew the smart DNS panel certificates
#
#[Service]
#Type=oneshot
#ExecStart=/usr/local/bin/smartdns-cert --renew
#__END_CERT_SERVICE__

#__BEGIN_CERT_TIMER__
#[Unit]
#Description=Twice-daily certificate renewal check
#
#[Timer]
## Twice a day is what Let's Encrypt asks for. certbot itself decides what is
## actually due, so almost every run does nothing; the point is that a
## certificate never gets close to expiring unnoticed.
#OnCalendar=*-*-* 03,15:00:00
#RandomizedDelaySec=3h
#Persistent=true
#
#[Install]
#WantedBy=timers.target
#__END_CERT_TIMER__

#__BEGIN_ADMIN__
##!/usr/bin/env python3
#"""smartdns-admin - the operator's web panel.
#
#A separate process from smartdns-panel, sharing its database. Separate because
#the bot must not go down while this is being restarted, and because a bug in a
#web form should not take the thing that talks to customers with it. sqlite is
#in WAL mode, so two processes writing short transactions is fine.
#
#Three things stand in front of it, and none of them is sufficient alone:
#
#  a port nobody scans for   keeps it out of the way, nothing more
#  a random path prefix      an unguessable URL, not a credential
#  a password               the actual authentication
#
#Security by obscurity is not security, so the password is the real control and
#the other two only reduce how often anyone finds the door at all. Optional
#address locking is available and switched off by default: the operator's home
#address is dynamic, and locking to it would eventually shut them out.
#
#Standard library only, like everything else here, so the installer keeps
#needing no pip step. No CDN either - the pages are opened from Iran, and every
#font and stylesheet host worth using is either blocked or slow.
#"""
#
#import hashlib
#import hmac
#import html
#import http.cookies
#import http.server
#import json
#import os
#import re
#import secrets
#import sqlite3
#import ssl
#import subprocess
#import sys
#import threading
#import time
#import urllib.parse
#from datetime import datetime, timedelta, timezone
#
#CONFIG = "/etc/smart-dns/admin.env"
#DB = "/var/lib/smart-dns/panel.db"
#SERVICES_FILE = "/usr/local/share/smart-dns/services.json"
#
#GB = 1024 ** 3
#SESSION_HOURS = 12
## Failed logins allowed from one address before it is made to wait. A password
## is the real defence, so this only has to make guessing slow rather than
## impossible.
#MAX_TRIES = 8
#LOCKOUT_SECONDS = 900
## The database is small - a few hundred kilobytes - so this is a ceiling on
## nonsense rather than a real limit on backups.
#MAX_UPLOAD = 64 * 1024 * 1024
#
#
#def systemctl(*args):
#    """Nudge a unit, without letting a failure here become a traceback.
#
#    Used either side of a restore. If systemd is not reachable the restore
#    itself has still happened and the operator can restart by hand, so this
#    reports and carries on rather than raising.
#    """
#    try:
#        r = subprocess.run(["systemctl"] + list(args), capture_output=True,
#                           text=True, timeout=30)
#        if r.returncode != 0:
#            print("systemctl %s: %s" % (" ".join(args), r.stderr.strip()),
#                  file=sys.stderr, flush=True)
#        return r.returncode == 0
#    except Exception as e:
#        print("systemctl %s failed: %r" % (" ".join(args), e),
#              file=sys.stderr, flush=True)
#        return False
#
#
#def now():
#    return datetime.now(timezone.utc).isoformat(timespec="seconds")
#
#
#def human(n):
#    n = float(n or 0)
#    for unit in ("B", "KB", "MB", "GB", "TB"):
#        if n < 1024 or unit == "TB":
#            return ("%d %s" if unit == "B" else "%.2f %s") % (n, unit)
#        n /= 1024
#
#
#def parse_ts(s):
#    if not s:
#        return None
#    try:
#        t = datetime.fromisoformat(s)
#    except ValueError:
#        return None
#    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)
#
#
#def panel_host():
#    """The name this panel is reachable by - whatever its certificate is for.
#
#    It listens on every address the machine has, but only this name matches
#    the certificate, so it is the only one worth printing back.
#    """
#    cert = CFG.get("ADMIN_CERT", "")
#    if cert.startswith("/etc/letsencrypt/live/"):
#        return cert.split("/")[4]
#    return "this-server"
#
#
## Ports that belong to the service itself. Moving the panel onto one of them
## takes down the thing it exists to administer.
#RESERVED_PORTS = {53: "DNS", 80: "HTTP", 443: "HTTPS",
#                  8443: "the relays' sync API", 22: "SSH"}
#
#
#def remaining_days(ts):
#    """Days left until `ts`, as placeholder text for the day field.
#
#    Shown greyed inside the input rather than as its value, so that saving a
#    row without touching the field does not silently reset the clock to
#    whatever it happened to say.
#    """
#    when = parse_ts(ts)
#    if not when:
#        return "بی‌نهایت"
#    left = (when - datetime.now(timezone.utc)).total_seconds() / 86400.0
#    if left <= 0:
#        return "تمام"
#    return "%d روز" % max(1, round(left))
#
#
#def load_config():
#    cfg = {}
#    with open(CONFIG) as fh:
#        for line in fh:
#            line = line.strip()
#            if not line or line.startswith("#") or "=" not in line:
#                continue
#            k, v = line.split("=", 1)
#            cfg[k.strip()] = v.strip().strip('"').strip("'")
#    for required in ("ADMIN_PATH", "ADMIN_HASH", "ADMIN_SALT", "ADMIN_PORT"):
#        if not cfg.get(required):
#            sys.exit("%s: %s is missing" % (CONFIG, required))
#    return cfg
#
#
#def hash_password(password, salt):
#    # 200k rounds: slow enough that guessing at scale is pointless, fast enough
#    # that a login is not noticeable.
#    return hashlib.pbkdf2_hmac(
#        "sha256", password.encode(), bytes.fromhex(salt), 200_000).hex()
#
#
## ------------------------------------------------------------------ storage
#class Store:
#    def __init__(self, path):
#        self.lock = threading.Lock()
#        self.db = sqlite3.connect(path, check_same_thread=False, timeout=15)
#        self.db.row_factory = sqlite3.Row
#        self.db.execute("PRAGMA foreign_keys = ON")
#        self.db.execute("PRAGMA journal_mode = WAL")
#
#        # Created here as well as in the panel's schema: this process can be
#        # the first to open the database on a machine where the panel has not
#        # started yet, and a missing table would mean nobody could sign in.
#        self.db.execute(
#            "CREATE TABLE IF NOT EXISTS admin_sessions ("
#            " token TEXT PRIMARY KEY, expires_at TEXT NOT NULL)")
#        self.db.commit()
#
#    def q(self, sql, args=()):
#        with self.lock:
#            return self.db.execute(sql, args).fetchall()
#
#    def one(self, sql, args=()):
#        rows = self.q(sql, args)
#        return rows[0] if rows else None
#
#    def run(self, sql, args=()):
#        with self.lock:
#            cur = self.db.execute(sql, args)
#            self.db.commit()
#            return cur
#
#    # The same two reads smartdns-panel does, spelled the same way. This panel
#    # keeps its own connection rather than importing that one, so they are
#    # written twice on purpose - but they must agree, because one writes what
#    # the other turns into the relays' bypass lists.
#    def template_groups(self, template_id):
#        return {(r["service_key"], r["group_key"]) for r in self.q(
#            "SELECT service_key, group_key FROM template_services"
#            " WHERE template_id = ?", (template_id,))}
#
#    def template_domains_off(self, template_id):
#        return {r["domain"] for r in self.q(
#            "SELECT domain FROM template_domains_off WHERE template_id = ?",
#            (template_id,))}
#
#    def snapshot(self, path):
#        """A consistent copy of the database at `path`, minus the metrics.
#
#        VACUUM INTO rather than copying the file: sqlite is in WAL mode, so
#        what is on disk is not the whole story and a copy taken while the bot
#        is writing can produce something that will not open.
#
#        Health samples are dropped. They are the bulk of the rows and none of
#        the value - what matters in a restore is who the customers are, what
#        they bought and what they have used.
#        """
#        with self.lock:
#            self.db.execute("VACUUM INTO ?", (path,))
#        copy = sqlite3.connect(path)
#        try:
#            copy.execute("DELETE FROM metrics")
#            copy.commit()
#            copy.execute("VACUUM")
#        finally:
#            copy.close()
#        return path
#
#    def close(self):
#        with self.lock:
#            self.db.close()
#
#
#def inspect_backup(path):
#    """Check a file really is one of our backups, and say what is in it.
#
#    Raises rather than returning a verdict, because every caller wants to stop.
#    Opening as sqlite is not enough: somebody's unrelated database would pass
#    that and then replace every customer with nothing.
#    """
#    db = sqlite3.connect(path)
#    try:
#        status = db.execute("PRAGMA integrity_check").fetchone()[0]
#        if status != "ok":
#            raise ValueError("integrity check failed: %s" % status)
#        have = {r[0] for r in db.execute(
#            "SELECT name FROM sqlite_master WHERE type = 'table'")}
#        missing = {"users", "ips", "templates", "settings"} - have
#        if missing:
#            raise ValueError("not a panel backup - missing %s"
#                             % ", ".join(sorted(missing)))
#        return {t: db.execute("SELECT count(*) FROM " + t).fetchone()[0]
#                for t in ("users", "ips", "templates", "transactions")}
#    finally:
#        db.close()
#
#
#def parse_upload(body, content_type, field):
#    """Pull one file out of a multipart/form-data body.
#
#    Hand-written because the stdlib's cgi module was removed in Python 3.13
#    and this panel is not allowed a pip step. One field is all that is needed,
#    so the parser only has to find its part and hand back the bytes between
#    that part's blank line and the next boundary.
#    """
#    marker = "boundary="
#    if marker not in (content_type or ""):
#        raise ValueError("not a file upload")
#    boundary = content_type.split(marker, 1)[1].strip().strip('"')
#    sep = b"--" + boundary.encode("latin-1")
#    want = ('name="%s"' % field).encode("latin-1")
#    for part in body.split(sep):
#        head, blank, data = part.partition(b"\r\n\r\n")
#        if not blank or want not in head:
#            continue
#        # The bytes before the next boundary carry a trailing CRLF that
#        # belongs to the delimiter, not to the file.
#        return data[:-2] if data.endswith(b"\r\n") else data
#    raise ValueError("no file was chosen")
#
#
## A checked backup waiting for the operator to confirm. In memory on purpose:
## a pending restore should not survive a restart, because nobody would
## remember agreeing to it.
#PENDING = {}
#
#
#CATALOGUE = []
#
#
#def load_catalogue():
#    try:
#        with open(SERVICES_FILE, encoding="utf-8") as fh:
#            services = json.load(fh).get("services", [])
#    except Exception:
#        services = []
#    services.append({"key": "custom", "label": "دامنه‌های دلخواه شما",
#                     "groups": [{"key": "main", "label": "همه", "domains": []}]})
#    return services
#
#
## -------------------------------------------------------------------- pages
#CSS = """
#*{box-sizing:border-box}
#body{margin:0;background:#0f1115;color:#e6e8eb;font:14px/1.7 system-ui,'Segoe UI',Tahoma,sans-serif}
#a{color:#7dd3a0;text-decoration:none}
#.wrap{max-width:1000px;margin:0 auto;padding:24px}
#header{display:flex;align-items:center;justify-content:space-between;
# border-bottom:1px solid #262b36;padding-bottom:14px;margin-bottom:22px;flex-wrap:wrap;gap:12px}
#h1{font-size:18px;margin:0;font-weight:600}
#nav a{margin-left:16px;color:#9aa4b2;font-size:14px}
#nav a.on{color:#7dd3a0;font-weight:600}
#.card{background:#171a21;border:1px solid #262b36;border-radius:12px;padding:18px;margin-bottom:16px}
#.card h2{font-size:15px;margin:0 0 14px;font-weight:600;color:#c9d1d9}
#table{width:100%;border-collapse:collapse;font-size:13px}
#th{text-align:right;color:#8b949e;font-weight:500;padding:8px 6px;border-bottom:1px solid #262b36}
#td{padding:9px 6px;border-bottom:1px solid #1c2029}
#tr:last-child td{border-bottom:0}
#code{background:#0f1115;padding:2px 6px;border-radius:5px;color:#7dd3a0;font-size:12px}
#.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:12px}
#.stat{background:#0f1115;border:1px solid #262b36;border-radius:10px;padding:14px}
#.stat .n{font-size:21px;font-weight:600}
#.stat .l{color:#8b949e;font-size:12px;margin-top:3px}
#.bar{height:6px;background:#0f1115;border-radius:3px;overflow:hidden;margin-top:7px}
#.bar i{display:block;height:100%;background:#7dd3a0}
#.bar i.warn{background:#e3b341}
#.bar i.hot{background:#f85149}
#input,select,button,textarea{font:inherit;background:#0f1115;color:#e6e8eb;
# border:1px solid #30363d;border-radius:7px;padding:8px 10px}
#button{background:#238636;border-color:#238636;cursor:pointer;font-weight:600}
#button:hover{background:#2ea043}
#button.danger{background:#6e2c2c;border-color:#6e2c2c}
#button.ghost{background:transparent;border-color:#30363d;color:#9aa4b2;font-weight:400}
#form.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
#.muted{color:#8b949e;font-size:12px}
#.ok{color:#7dd3a0}.bad{color:#f85149}.warn{color:#e3b341}
#.msg{padding:11px 14px;border-radius:9px;margin-bottom:16px;font-size:13px}
#.msg.good{background:#12261a;border:1px solid #238636}
#.msg.err{background:#2b1416;border:1px solid #6e2c2c}
#label{display:block;color:#8b949e;font-size:12px;margin-bottom:5px}
#.f{margin-bottom:12px}
#.login{max-width:340px;margin:14vh auto}
#.receipt{border:1px solid #262b36;border-radius:10px;padding:14px;
# margin-bottom:14px;background:#0f1115}
#.receipt .who{font-size:14px;font-weight:600;margin-bottom:10px}
#.receipt img{max-width:100%;max-height:420px;border-radius:8px;
# border:1px solid #262b36;display:block}
#td.acts{white-space:nowrap}
#td.acts form{display:inline}
#td.acts button{padding:6px 10px;font-size:12px;margin-right:4px}
#a.dl{display:inline-block;background:#238636;color:#fff;font-weight:600;
# padding:9px 16px;border-radius:7px;text-decoration:none}
#a.dl:hover{background:#2ea043}
#.svc{display:inline-block;margin:0 0 8px 14px}
#.svc label{display:inline;color:#e6e8eb;font-size:13px}
#details.svc{display:block;margin:0 0 6px;border:1px solid #262b36;border-radius:9px;
# background:#0f1115}
#details.svc>summary{padding:9px 12px;cursor:pointer;list-style:none;
# display:flex;align-items:center;gap:10px}
#details.svc>summary::-webkit-details-marker{display:none}
#details.svc>summary::before{content:'▸';color:#8b949e;font-size:11px;
# transition:transform .12s}
#details.svc[open]>summary::before{transform:rotate(-90deg)}
#details.svc[open]{border-color:#30363d}
#details.svc>summary label{flex:1}
#.doms{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));
# gap:2px 14px;padding:4px 30px 12px;border-top:1px solid #1c2029;margin-top:2px}
#.doms label{display:flex;align-items:center;gap:7px;color:#9aa4b2;font-size:12px;
# font-family:ui-monospace,Consolas,monospace;margin:0;padding:2px 0}
#.doms label span{direction:ltr;overflow:hidden;text-overflow:ellipsis;
# white-space:nowrap}
#.doms input{margin:0}
#.optin{display:block;font-size:11px;color:#e3b341;font-weight:400;margin-top:2px}
#.pick{margin-right:auto;display:flex;gap:6px}
#.pick button{padding:3px 10px;font-size:11px;font-weight:400;
# background:transparent;border:1px solid #30363d;color:#8b949e}
#.pick button:hover{background:#1c2029}
#"""
#
#
#def page(title, body, cfg, active="", msg=None, msg_kind="good"):
#    nav = ""
#    for path, label in (("", "خانه"), ("users", "کاربران"), ("receipts", "رسیدها"),
#                        ("templates", "قالب‌ها"), ("domains", "دامنه‌ها"),
#                        ("settings", "تنظیمات"), ("logs", "لاگ")):
#        cls = " class='on'" if active == path else ""
#        nav += "<a href='/%s/%s'%s>%s</a>" % (cfg["ADMIN_PATH"], path, cls, label)
#    banner = ""
#    if msg:
#        banner = "<div class='msg %s'>%s</div>" % (msg_kind, html.escape(msg))
#    return ("""<!doctype html><html lang="fa" dir="rtl"><head><meta charset="utf-8">
#<meta name="viewport" content="width=device-width,initial-scale=1">
#<link rel="icon" href="data:,">
#<title>%s</title><style>%s</style></head><body><div class="wrap">
#<header><h1>%s</h1><nav>%s<a href='/%s/logout'>خروج</a></nav></header>
#%s%s</div></body></html>""" % (html.escape(title), CSS, html.escape(title), nav,
#                               cfg["ADMIN_PATH"], banner, body))
#
#
#def login_page(cfg, error=None):
#    err = "<div class='msg err'>%s</div>" % html.escape(error) if error else ""
#    # The action is spelled out rather than left to default to the current
#    # URL. A form with no action posts wherever the browser happens to be,
#    # which after a bookmark to a page that has moved is not the panel.
#    return """<!doctype html><html lang="fa" dir="rtl"><head><meta charset="utf-8">
#<meta name="viewport" content="width=device-width,initial-scale=1">
#<link rel="icon" href="data:,">
#<title>ورود</title><style>%s</style></head><body><div class="wrap"><div class="login">
#<div class="card"><h2>پنل مدیریت</h2>%s
#<form method="post" action="/%s/"><div class="f"><label>رمز عبور</label>
#<input type="password" name="password" autofocus style="width:100%%"></div>
#<button type="submit" style="width:100%%">ورود</button></form></div>
#</div></div></body></html>""" % (CSS, err, cfg["ADMIN_PATH"])
#
#
#def bar(used, total):
#    if not total:
#        return "<span class='muted'>-</span>"
#    pct = min(100, int(100.0 * used / total))
#    cls = "hot" if pct >= 90 else ("warn" if pct >= 75 else "")
#    return ("%d%% <span class='muted'>(%s از %s)</span>"
#            "<div class='bar'><i class='%s' style='width:%d%%'></i></div>"
#            % (pct, human(used), human(total), cls, pct))
#
#
## ----------------------------------------------------------------- handler
## Sessions live in the database, not in this process. They used to be a dict,
## which meant every restart signed the operator out - and this panel restarts
## whenever it is upgraded, whenever its port or path is changed, and after a
## restore. Being signed out is not only an annoyance: without a session, a
## visit to the bare address is answered with the same bare 404 a stranger
## gets, which is how "the panel 404s sometimes" was really happening.
##
## Failed attempts stay in memory. Losing that count on restart only makes
## guessing slightly easier for someone who cannot cause restarts anyway.
#ATTEMPTS = {}          # address -> [count, first_failure_time]
#STORE = None
#CFG = {}
#
#
#class Admin(http.server.BaseHTTPRequestHandler):
#    server_version = "smartdns"
#    protocol_version = "HTTP/1.1"
#
#    def log_message(self, *a):
#        pass
#
#    # -- plumbing ---------------------------------------------------------
#    def send(self, body, code=200, headers=None):
#        blob = body.encode("utf-8") if isinstance(body, str) else body
#        # Start the header buffer clean. Nothing reaches the socket until
#        # end_headers(), so a send() that raised part-way through leaves a
#        # half-written status line behind; without this, the error page that
#        # follows is appended to it and the browser is handed two responses in
#        # one - which it reports as corrupted content rather than as an error.
#        self._headers_buffer = []
#        self.send_response(code)
#        self.send_header("Content-Type", "text/html; charset=utf-8")
#        self.send_header("Content-Length", str(len(blob)))
#        # This panel is only ever reached over TLS, and none of it should sit
#        # in a cache or be framed by anything.
#        self.send_header("Cache-Control", "no-store")
#        self.send_header("X-Frame-Options", "DENY")
#        self.send_header("X-Content-Type-Options", "nosniff")
#        self.send_header("Referrer-Policy", "no-referrer")
#        for k, v in (headers or {}).items():
#            self.send_header(k, v)
#        self.end_headers()
#        self.wfile.write(blob)
#
#    def redirect(self, path, headers=None):
#        """Redirect, percent-encoding anything that is not plain ascii.
#
#        Every message this panel shows after an action is Persian, and it
#        travels in the query string of a Location header. A header can only
#        carry latin-1, so an unencoded message makes send_header raise in the
#        middle of the response - which the browser reports as corrupted
#        content, after the action has already been carried out.
#        """
#        base, sep, query = path.lstrip("/").partition("?")
#        if sep:
#            fields = []
#            for item in query.split("&"):
#                key, _, value = item.partition("=")
#                fields.append("%s=%s" % (key, urllib.parse.quote(value, safe="")))
#            query = "?" + "&".join(fields)
#        h = {"Location": "/%s/%s%s" % (CFG["ADMIN_PATH"], base, query)}
#        h.update(headers or {})
#        self.send("", 303, h)
#
#    def body_params(self):
#        length = int(self.headers.get("Content-Length", 0) or 0)
#        # A file upload is read as bytes elsewhere; decoding a database as
#        # utf-8 and running it through parse_qs would be nonsense.
#        if "multipart/form-data" in (self.headers.get("Content-Type") or ""):
#            self.raw_body = self.rfile.read(min(length, MAX_UPLOAD))
#            return {}
#        raw = self.rfile.read(length).decode("utf-8", "replace") if length else ""
#        return urllib.parse.parse_qs(raw, keep_blank_values=True)
#
#    # -- backup and restore ----------------------------------------------
#    def send_backup(self):
#        stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
#        # Beside the database rather than in /tmp: the unit sets PrivateTmp, so
#        # /tmp is a mount point of its own, and the restore path below cannot
#        # rename across one.
#        path = os.path.join(os.path.dirname(DB), ".backup-%s.db" % stamp)
#        try:
#            STORE.snapshot(path)
#            with open(path, "rb") as fh:
#                blob = fh.read()
#        except Exception as e:
#            print("backup failed: %r" % e, file=sys.stderr, flush=True)
#            return self.redirect("settings?m=!پشتیبان‌گیری نشد: %s" % e)
#        finally:
#            try:
#                os.unlink(path)
#            except OSError:
#                pass
#        return self.send(blob, 200, {
#            "Content-Type": "application/octet-stream",
#            "Content-Disposition":
#                'attachment; filename="smartdns-backup-%s.db"' % stamp})
#
#    # -- receipts ---------------------------------------------------------
#    def send_receipt(self, ident):
#        """Hand back the stored image itself, for the <img> on the page.
#
#        Served from here rather than inlined as a data URI: the page lists
#        every pending receipt, and inlining several megabytes of base64 into
#        the HTML would make the list slow to open over an Iranian connection
#        even when the operator only wants to glance at one.
#        """
#        row = STORE.one("SELECT receipt_blob, receipt_type FROM transactions"
#                        " WHERE id = ?", (int(ident) if ident.isdigit() else 0,))
#        if not row or not row["receipt_blob"]:
#            return self.send("<h1>404</h1>", 404)
#        return self.send(bytes(row["receipt_blob"]), 200, {
#            "Content-Type": row["receipt_type"] or "application/octet-stream",
#            # Not inline for a PDF: opening one in the panel's own origin is a
#            # needless way to run somebody else's file next to the session.
#            "Content-Disposition": "inline; filename=receipt-%s" % ident})
#
#    def receipts(self):
#        p = CFG["ADMIN_PATH"]
#        rows = STORE.q(
#            "SELECT t.*, u.first_name, u.username, u.phone, u.telegram_id,"
#            " length(t.receipt_blob) AS size"
#            " FROM transactions t JOIN users u ON u.id = t.user_id"
#            " ORDER BY CASE t.status WHEN 'pending' THEN 0 ELSE 1 END,"
#            " t.created_at DESC LIMIT 100")
#        pending = [r for r in rows if r["status"] == "pending"]
#        out = ["<div class='card'><h2>رسیدهای در انتظار (%d)</h2>" % len(pending)]
#        if not pending:
#            out.append("<p class='muted'>رسیدی نرسیده.</p>")
#        for r in pending:
#            who = (r["first_name"] or "") + " · " + (
#                r["username"] or r["phone"]
#                or str(r["telegram_id"] or "#%d" % r["user_id"]))
#            out.append(
#                "<div class='receipt'>"
#                "<div class='who'>%s<span class='muted'> · %s · %s</span></div>"
#                "<a href='/%s/receipt/%d' target='_blank'>"
#                "<img src='/%s/receipt/%d' alt='رسید'></a>"
#                "<div class='row' style='margin-top:10px'>"
#                "<form method='post' action='/%s/receipt-decide'>"
#                "<input type='hidden' name='id' value='%d'>"
#                "<input type='hidden' name='to' value='approved'>"
#                "<button>تأیید</button></form>"
#                "<form method='post' action='/%s/receipt-decide'>"
#                "<input type='hidden' name='id' value='%d'>"
#                "<input type='hidden' name='to' value='rejected'>"
#                "<button class='danger'>رد</button></form>"
#                "<a class='muted' href='/%s/users'>ویرایش حساب این کاربر ←</a>"
#                "</div></div>"
#                % (html.escape(who), html.escape(r["created_at"][:16]),
#                   human(r["size"] or 0),
#                   p, r["id"], p, r["id"], p, r["id"], p, r["id"], p))
#        out.append("<p class='muted'>تأیید یا رد فقط تصمیم را ثبت می‌کند و عکس "
#                   "را پاک می‌کند؛ سهمیه و زمان را خودتان در صفحهٔ کاربران "
#                   "می‌گذارید.</p></div>")
#
#        decided = [r for r in rows if r["status"] != "pending"]
#        if decided:
#            out.append("<div class='card'><h2>تصمیم‌های قبلی</h2>"
#                       "<table><tr><th>کاربر</th><th>رسید</th><th>تصمیم</th>"
#                       "<th>تاریخ</th></tr>")
#            for r in decided[:40]:
#                out.append("<tr><td>%s</td><td>%s</td><td class='%s'>%s</td>"
#                           "<td>%s</td></tr>"
#                           % (html.escape((r["first_name"] or "") + " · " +
#                                          (r["username"] or r["phone"] or "")),
#                              html.escape(r["created_at"][:16]),
#                              "ok" if r["status"] == "approved" else "bad",
#                              "تأیید شد" if r["status"] == "approved" else "رد شد",
#                              html.escape((r["decided_at"] or "")[:16])))
#            out.append("</table></div>")
#        return "".join(out)
#
#    def take_upload(self):
#        """Stage an uploaded file and describe it, or explain why it is no good."""
#        try:
#            blob = parse_upload(getattr(self, "raw_body", b""),
#                                self.headers.get("Content-Type"), "file")
#        except ValueError as e:
#            return self.redirect("settings?m=!%s" % e)
#        if not blob:
#            return self.redirect("settings?m=!فایل خالی بود")
#        if len(blob) >= MAX_UPLOAD:
#            return self.redirect("settings?m=!فایل خیلی بزرگ است")
#
#        path = os.path.join(os.path.dirname(DB),
#                            ".restore-%s.db" % secrets.token_hex(6))
#        with open(path, "wb") as fh:
#            fh.write(blob)
#        try:
#            counts = inspect_backup(path)
#        except Exception as e:
#            os.unlink(path)
#            return self.redirect("settings?m=!این فایل نسخهٔ پشتیبان سالمی نیست: %s" % e)
#
#        old = PENDING.pop("path", None)
#        if old and os.path.exists(old):
#            os.unlink(old)
#        PENDING.update({"path": path, "counts": counts, "size": len(blob)})
#        return self.redirect("restore")
#
#    def restore_page(self):
#        p = CFG["ADMIN_PATH"]
#        if not PENDING.get("path") or not os.path.exists(PENDING.get("path", "")):
#            return ("<div class='card'><h2>بازگردانی</h2><p class='muted'>فایلی "
#                    "برای بازگردانی منتظر نیست. از <a href='/%s/settings'>تنظیمات</a> "
#                    "یک نسخهٔ پشتیبان بفرستید.</p></div>" % p)
#        c = PENDING["counts"]
#        now_c = STORE.one(
#            "SELECT (SELECT count(*) FROM users) u, (SELECT count(*) FROM ips) i,"
#            " (SELECT count(*) FROM templates) t,"
#            " (SELECT count(*) FROM transactions) x")
#        rows = [("کاربران", c["users"], now_c["u"]),
#                ("آی‌پی‌های ثبت‌شده", c["ips"], now_c["i"]),
#                ("قالب‌ها", c["templates"], now_c["t"]),
#                ("تراکنش‌ها", c["transactions"], now_c["x"])]
#        body = ["<div class='card'><h2>این فایل جایگزین دیتابیس فعلی شود؟</h2>",
#                "<p class='muted'>حجم فایل: %s</p>" % human(PENDING["size"]),
#                "<table class='tbl'><tr><th></th><th>در فایل</th>"
#                "<th>الان در سرویس</th></tr>"]
#        for label, new, old in rows:
#            cls = "" if new == old else " class='warn'"
#            body.append("<tr><td>%s</td><td%s>%d</td><td>%d</td></tr>"
#                        % (label, cls, new, old))
#        body.append("</table>")
#        body.append(
#            "<div class='msg err' style='margin-top:18px'>بازگردانی، دیتابیس "
#            "فعلی را کامل جایگزین می‌کند. از وضعیت فعلی قبلش یک نسخه کنار "
#            "دیتابیس نگه داشته می‌شود، پس این کار برگشت‌پذیر است — ولی سرویس "
#            "چند ثانیه‌ای ری‌استارت می‌شود.</div>")
#        body.append(
#            "<form method='post' action='/%s/restore-apply' style='display:inline'>"
#            "<button class='danger'>بله، جایگزین کن</button></form> "
#            "<form method='post' action='/%s/restore-cancel' style='display:inline'>"
#            "<button class='ghost'>انصراف</button></form></div>" % (p, p))
#        return "".join(body)
#
#    def moving_to(self, port, path):
#        """Hand back the new address, then restart onto it.
#
#        A redirect would be wrong: the browser would follow it to the old
#        address, which is about to stop answering. So this is a page, with the
#        new address on it, and the restart happens a second later - by which
#        time the operator has the link in front of them.
#        """
#        url = "https://%s:%s/%s/" % (panel_host(), port, path)
#        self.send(page("آدرس تازه",
#                       "<div class='card'><h2>آدرس پنل عوض شد</h2>"
#                       "<p>از این به بعد اینجاست — همین حالا ذخیره‌اش کنید:</p>"
#                       "<p><code>%s</code></p>"
#                       "<p class='muted'>پنل تا چند ثانیهٔ دیگر روی آدرس تازه "
#                       "بالا می‌آید. اگر باز نشد، به احتمال زیاد فایروال یا "
#                       "security group سرور پورت را نمی‌گذارد رد شود؛ از روی "
#                       "خود سرور با <code>smartdns-access</code> برش گردانید."
#                       "</p></div>" % html.escape(url), CFG, "settings"),
#                  200, {"Refresh": "6; url=%s" % url})
#        try:
#            self.wfile.flush()
#        except Exception:
#            pass
#        print("panel moving to %s" % url, flush=True)
#        threading.Timer(1.0, os._exit, (0,)).start()
#
#    def apply_restore(self):
#        path = PENDING.get("path")
#        if not path or not os.path.exists(path):
#            return self.redirect("settings?m=!چیزی برای بازگردانی نیست")
#        keep = "%s.before-restore-%s" % (
#            DB, datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S"))
#        try:
#            STORE.snapshot(keep)
#            # Stop the bot before the swap. It holds the old file open and
#            # keeps writing to the journal beside it; deleting that journal
#            # underneath a running process is how a restore becomes corruption.
#            systemctl("stop", "smartdns-panel")
#            STORE.close()
#            os.replace(path, DB)
#            for suffix in ("-wal", "-shm"):
#                try:
#                    os.unlink(DB + suffix)
#                except OSError:
#                    pass
#            systemctl("start", "smartdns-panel")
#        except Exception as e:
#            print("restore failed: %r" % e, file=sys.stderr, flush=True)
#            systemctl("start", "smartdns-panel")
#            return self.redirect("settings?m=!بازگردانی نشد: %s" % e)
#        PENDING.clear()
#
#        p = CFG["ADMIN_PATH"]
#        self.send(page("بازگردانی شد",
#                       "<div class='card'><h2>بازگردانی شد</h2>"
#                       "<p>نسخهٔ قبلی اینجا نگه داشته شد:</p><p><code>%s</code></p>"
#                       "<p class='muted'>این پنل هم دارد ری‌استارت می‌شود تا "
#                       "دیتابیس تازه را باز کند. چند ثانیه دیگر خودش برمی‌گردد.</p>"
#                       "<p><a href='/%s/users'>رفتن به کاربران</a></p></div>"
#                       % (html.escape(keep), p),
#                       CFG, "settings"),
#                  200, {"Refresh": "16; url=/%s/users" % p})
#        try:
#            self.wfile.flush()
#        except Exception:
#            pass
#        # This process still has the replaced file open, so the only honest way
#        # to pick up the new one is to let systemd start us again.
#        print("restarting after restore", flush=True)
#        threading.Timer(1.0, os._exit, (0,)).start()
#
#    @staticmethod
#    def one(params, key, default=""):
#        return (params.get(key) or [default])[0].strip()
#
#    # -- auth -------------------------------------------------------------
#    def session_token(self):
#        cookie = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
#        return cookie["sdns"].value if "sdns" in cookie else ""
#
#    def session_ok(self):
#        token = self.session_token()
#        if not token:
#            return False
#        row = STORE.one("SELECT expires_at FROM admin_sessions WHERE token = ?",
#                        (token,))
#        if not row:
#            return False
#        if (parse_ts(row["expires_at"]) or datetime.now(timezone.utc))                 <= datetime.now(timezone.utc):
#            STORE.run("DELETE FROM admin_sessions WHERE token = ?", (token,))
#            return False
#        return True
#
#    def locked_out(self):
#        rec = ATTEMPTS.get(self.client_address[0])
#        if not rec:
#            return False
#        count, first = rec
#        if time.time() - first > LOCKOUT_SECONDS:
#            ATTEMPTS.pop(self.client_address[0], None)
#            return False
#        return count >= MAX_TRIES
#
#    def note_failure(self):
#        addr = self.client_address[0]
#        count, first = ATTEMPTS.get(addr, (0, time.time()))
#        ATTEMPTS[addr] = (count + 1, first)
#
#    # -- routing ----------------------------------------------------------
#    def route(self):
#        prefix = "/" + CFG["ADMIN_PATH"]
#        path = urllib.parse.urlparse(self.path).path
#        if not path.startswith(prefix):
#            return None
#        rest = path[len(prefix):].strip("/")
#        return rest
#
#    def lost(self):
#        """Answer a request that did not name the secret path.
#
#        A stranger gets a bare 404 and learns nothing - that is the whole
#        point of the path. Somebody already holding a valid session is not a
#        stranger: they have full access already, so sending them to the panel
#        reveals nothing and saves them from the commonest way to meet this
#        page, which is typing the host without the path, or following a
#        bookmark from before the path or port was changed.
#        """
#        if self.session_ok():
#            return self.redirect("")
#        path = urllib.parse.urlparse(self.path).path
#        # Logged so that "it 404s sometimes" is answerable next time. Only
#        # paths that missed the prefix, so the secret never reaches the
#        # journal.
#        if not path.startswith("/" + CFG["ADMIN_PATH"]):
#            print("404 %s from %s" % (path[:80], self.client_address[0]),
#                  file=sys.stderr, flush=True)
#        return self.send("<h1>404</h1>", 404)
#
#    def do_GET(self):
#        rest = self.route()
#        if rest is None:
#            return self.lost()
#        if rest == "logout":
#            cookie = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
#            if "sdns" in cookie:
#                STORE.run("DELETE FROM admin_sessions WHERE token = ?",
#                          (cookie["sdns"].value,))
#            return self.redirect("", {"Set-Cookie": "sdns=; Max-Age=0; Path=/"})
#        if not self.session_ok():
#            return self.send(login_page(CFG))
#        if rest == "backup.db":
#            return self.send_backup()
#        if rest.startswith("receipt/"):
#            return self.send_receipt(rest.split("/", 1)[1])
#        try:
#            return self.view(rest)
#        except Exception as e:
#            print("admin GET %s failed: %r" % (rest, e), file=sys.stderr, flush=True)
#            return self.send(page("خطا", "<div class='card'>%s</div>"
#                                  % html.escape(str(e)), CFG), 500)
#
#    def do_POST(self):
#        rest = self.route()
#        if rest is None:
#            return self.lost()
#        params = self.body_params()
#        if not self.session_ok():
#            if self.locked_out():
#                return self.send(login_page(
#                    CFG, "تلاش‌های ناموفق زیاد. چند دقیقه صبر کنید."))
#            given = self.one(params, "password")
#            want = CFG["ADMIN_HASH"]
#            if given and hmac.compare_digest(
#                    hash_password(given, CFG["ADMIN_SALT"]), want):
#                token = secrets.token_urlsafe(32)
#                STORE.run(
#                    "INSERT OR REPLACE INTO admin_sessions (token, expires_at)"
#                    " VALUES (?, ?)",
#                    (token, (datetime.now(timezone.utc)
#                             + timedelta(hours=SESSION_HOURS)).isoformat(
#                                 timespec="seconds")))
#                # Tidy up whatever has run out, so the table cannot grow
#                # forever on a panel that is logged into daily.
#                STORE.run("DELETE FROM admin_sessions WHERE expires_at <= ?",
#                          (now(),))
#                ATTEMPTS.pop(self.client_address[0], None)
#                return self.redirect("", {
#                    "Set-Cookie": "sdns=%s; Path=/; HttpOnly; Secure; SameSite=Strict"
#                                  % token})
#            self.note_failure()
#            return self.send(login_page(CFG, "رمز اشتباه است."))
#        try:
#            return self.action(rest, params)
#        except Exception as e:
#            print("admin POST %s failed: %r" % (rest, e), file=sys.stderr, flush=True)
#            return self.send(page("خطا", "<div class='card'>%s</div>"
#                                  % html.escape(str(e)), CFG), 500)
#
#    # -- views ------------------------------------------------------------
#    def view(self, rest):
#        msg = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("m")
#        msg = msg[0] if msg else None
#        kind = "err" if (msg or "").startswith("!") else "good"
#        msg = msg.lstrip("!") if msg else None
#        pages = {"": ("پنل مدیریت", self.home), "index": ("پنل مدیریت", self.home),
#                 "users": ("کاربران", self.users),
#                 "receipts": ("رسیدها", self.receipts),
#                 "templates": ("قالب‌ها", self.templates),
#                 "domains": ("دامنه‌ها", self.domains),
#                 "settings": ("تنظیمات", self.settings),
#                 "restore": ("بازگردانی", self.restore_page),
#                 "logs": ("لاگ", self.logs)}
#        if rest not in pages:
#            return self.lost()
#        title, fn = pages[rest]
#        active = "" if rest == "index" else rest
#        return self.send(page(title, fn(), CFG, active, msg, kind))
#
#    def home(self):
#        u = STORE.one("SELECT count(*) c, COALESCE(sum(used_bytes),0) b FROM users")
#        act = STORE.one("SELECT count(*) c FROM users WHERE status = 'active'")
#        ips = STORE.one("SELECT count(*) c FROM ips")
#        out = ["<div class='card'><h2>خلاصه</h2><div class='grid'>"]
#        for n, l in ((u["c"], "کاربر"), (act["c"], "فعال"),
#                     (ips["c"], "آی‌پی ثبت‌شده"), (human(u["b"]), "مجموع مصرف")):
#            out.append("<div class='stat'><div class='n'>%s</div>"
#                       "<div class='l'>%s</div></div>" % (html.escape(str(n)), l))
#        out.append("</div></div>")
#
#        rows = STORE.q("SELECT m.* FROM metrics m JOIN (SELECT host, MAX(at) at"
#                       " FROM metrics GROUP BY host) l"
#                       " ON l.host = m.host AND l.at = m.at ORDER BY m.host")
#        out.append("<div class='card'><h2>سرورها</h2>")
#        if not rows:
#            out.append("<p class='muted'>هنوز آماری نرسیده.</p>")
#        else:
#            out.append("<table><tr><th>سرور</th><th>CPU</th><th>RAM</th>"
#                       "<th>SWAP</th><th>دیسک</th><th>شبکه</th><th>روشن</th></tr>")
#            for r in rows:
#                seen = parse_ts(r["at"])
#                stale = ""
#                if seen and (datetime.now(timezone.utc) - seen).total_seconds() > 120:
#                    stale = " <span class='bad'>قطع</span>"
#                swap = (bar(r["swap_used"], r["swap_total"]) if r["swap_total"]
#                        else "<span class='muted'>ندارد</span>")
#                out.append(
#                    "<tr><td><code>%s</code>%s</td><td>%s%%</td><td>%s</td>"
#                    "<td>%s</td><td>%s</td>"
#                    "<td class='muted'>↓%s/s ↑%s/s</td>"
#                    "<td class='muted'>%d روز</td></tr>"
#                    % (html.escape(r["host"]), stale, r["cpu"],
#                       bar(r["mem_used"], r["mem_total"]), swap,
#                       bar(r["disk_used"], r["disk_total"]),
#                       human(r["rx_bps"]), human(r["tx_bps"]),
#                       (r["uptime"] or 0) // 86400))
#            out.append("</table>")
#        out.append("</div>")
#        return "".join(out)
#
#    def users(self):
#        tpls = STORE.q("SELECT * FROM templates ORDER BY id")
#        default = STORE.one("SELECT id FROM templates WHERE is_default = 1")
#        did = default["id"] if default else 0
#        rows = STORE.q("SELECT u.*, (SELECT ip FROM ips WHERE user_id = u.id LIMIT 1)"
#                       " ip FROM users u ORDER BY u.created_at DESC")
#        out = ["<div class='card'><h2>کاربران (%d)</h2>" % len(rows)]
#        if not rows:
#            return "".join(out) + "<p class='muted'>هنوز کسی ثبت‌نام نکرده.</p></div>"
#        out.append("<table><tr><th>نام کاربری</th><th>آی‌پی</th><th>مصرف</th>"
#                   "<th>سهمیه (گیگ)</th><th>سرعت Mb/s</th><th>زمان (روز)</th>"
#                   "<th>قالب</th><th>وضعیت</th><th></th></tr>")
#        p = CFG["ADMIN_PATH"]
#        for r in rows:
#            tid = r["template_id"] or did
#            sel = "".join("<option value='%d'%s>%s</option>"
#                          % (t["id"], " selected" if t["id"] == tid else "",
#                             html.escape(t["name"])) for t in tpls)
#            # "pending" is amber, not red: nothing is wrong with the
#            # account, it is only waiting for somebody here to give it a plan.
#            cls = {"active": "ok", "over_quota": "warn",
#                   "pending": "warn"}.get(r["status"], "bad")
#            label = {"active": "فعال", "pending": "در انتظار پلن",
#                     "over_quota": "سهمیه تمام شده", "expired": "منقضی",
#                     "suspended": "مسدود"}.get(r["status"], r["status"])
#            quota_gb = ("%.0f" % (r["quota_bytes"] / GB)) if r["quota_bytes"] else "0"
#            kbps = r["speed_kbps"] or 0
#            speed_mb = ("%g" % (kbps / 1000.0)) if kbps else "0"
#            left = remaining_days(r["expires_at"] or r["quota_reset_at"])
#            out.append(
#                "<tr><td><code>%s</code><br><span class='muted'>%s</span></td>"
#                "<td><code>%s</code></td><td>%s</td>"
#                "<td><form id='u%d' method='post' action='/%s/user-save'></form>"
#                "<input form='u%d' type='hidden' name='id' value='%d'>"
#                "<input form='u%d' name='quota_gb' value='%s' size='4'"
#                " title='گیگابایت، ۰=نامحدود'></td>"
#                "<td><input form='u%d' name='speed_mb' value='%s' size='4'"
#                " title='مگابیت بر ثانیه، ۰=بی‌حد'></td>"
#                "<td><input form='u%d' name='days' size='4' placeholder='%s'"
#                " title='از امروز چند روز دیگر'></td>"
#                "<td><form method='post' action='/%s/user-template'>"
#                "<input type='hidden' name='id' value='%d'>"
#                "<select name='template_id' onchange='this.form.submit()'>%s</select>"
#                "</form></td>"
#                "<td class='%s'>%s</td>"
#                "<td class='acts'><button form='u%d' title='ذخیره'>ثبت</button>"
#                "<form method='post' action='/%s/user-status'>"
#                "<input type='hidden' name='id' value='%d'>"
#                "<input type='hidden' name='to' value='%s'>"
#                "<button class='%s' title='%s'>%s</button></form>"
#                "<form method='post' action='/%s/user-reset'"
#                " onsubmit='return confirm(\"مصرف این کاربر صفر شود؟\")'>"
#                "<input type='hidden' name='id' value='%d'>"
#                "<button class='ghost' title='صفر کردن مصرف'>صفر</button></form>"
#                "</td></tr>"
#                # What a customer signs in with. Accounts opened before this
#                # was a username have a phone number instead, and the ones
#                # that came through the bot have neither - so the column shows
#                # whichever this account actually has.
#                % (html.escape(str(r["username"] or r["phone"]
#                                   or r["telegram_id"] or "#%d" % r["id"])),
#                   html.escape(r["first_name"] or ""),
#                   html.escape(r["ip"] or "-"), human(r["used_bytes"]),
#                   r["id"], p, r["id"], r["id"], r["id"], quota_gb,
#                   r["id"], speed_mb, r["id"], left,
#                   p, r["id"], sel, cls, html.escape(label),
#                   r["id"],
#                   p, r["id"],
#                   "active" if r["status"] == "suspended" else "suspended",
#                   "ghost" if r["status"] == "suspended" else "danger",
#                   "برگرداندن" if r["status"] == "suspended" else "مسدود کردن",
#                   "فعال" if r["status"] == "suspended" else "مسدود",
#                   p, r["id"]))
#        out.append("</table><p class='muted'>ثبت‌نام تازه با وضعیت «در انتظار "
#                   "پلن» می‌آید و تا وقتی برایش پلن ذخیره نکنید هیچ ترافیکی "
#                   "نمی‌گیرد؛ اولین ذخیرهٔ همین سطر فعالش می‌کند. "
#                   "صفر در سهمیه یا سرعت یعنی بی‌حد. "
#                   "«زمان» خالی یعنی بدون تغییر؛ عددی که بنویسید تاریخ پایان را "
#                   "از امروز همان‌قدر روز جلو می‌برد، و رنگ خاکستریِ داخلش روزهای "
#                   "باقی‌مانده است. سرعت فقط دانلود را محدود می‌کند و تا ۳۰ ثانیه "
#                   "دیگر روی رله‌ها اعمال می‌شود.</p></div>")
#        return "".join(out)
#
#    def templates(self):
#        """Two pages behind one path: the list, and one template's editor.
#
#        Editing is its own page because the editor carries a checkbox for every
#        domain in the catalogue - some five hundred of them. Rendering that
#        for every template at once would make a page several times the size,
#        opened over a connection from Iran, to show one template's detail.
#        """
#        wanted = urllib.parse.parse_qs(
#            urllib.parse.urlparse(self.path).query).get("t")
#        if wanted:
#            row = STORE.one("SELECT * FROM templates WHERE id = ?",
#                            (int(wanted[0]) if wanted[0].isdigit() else 0,))
#            if row:
#                return self.template_editor(row)
#        return self.template_list()
#
#    def template_list(self):
#        tpls = STORE.q("SELECT * FROM templates ORDER BY id")
#        default = STORE.one("SELECT id FROM templates WHERE is_default = 1")
#        did = default["id"] if default else 0
#        p = CFG["ADMIN_PATH"]
#        out = ["<div class='card'><h2>قالب‌ها</h2>"
#               "<table><tr><th>نام</th><th>کاربر</th><th>سرویس‌ها</th>"
#               "<th>دامنه‌ها</th><th></th></tr>"]
#        for t in tpls:
#            users = STORE.one("SELECT count(*) c FROM users"
#                              " WHERE COALESCE(template_id, ?) = ?",
#                              (did, t["id"]))["c"]
#            name = html.escape(t["name"])
#            if t["is_default"]:
#                out.append("<tr><td>%s <span class='muted'>(پیش‌فرض)</span></td>"
#                           "<td>%d</td><td colspan='2' class='muted'>همه، از جمله "
#                           "سرویس‌هایی که بعداً اضافه شوند</td><td></td></tr>"
#                           % (name, users))
#                continue
#            groups = STORE.template_groups(t["id"])
#            off = STORE.template_domains_off(t["id"])
#            n_groups = n_dom = total_dom = 0
#            for svc in CATALOGUE:
#                for g in svc["groups"]:
#                    total_dom += len(g["domains"])
#                    if (svc["key"], g["key"]) in groups:
#                        n_groups += 1
#                        n_dom += sum(1 for d in g["domains"] if d not in off)
#            out.append("<tr><td>%s</td><td>%d</td><td>%d</td>"
#                       "<td>%d <span class='muted'>از %d</span></td>"
#                       "<td><a href='/%s/templates?t=%d'>ویرایش</a></td></tr>"
#                       % (name, users, n_groups, n_dom, total_dom, p, t["id"]))
#        out.append("</table></div>")
#        out.append("<div class='card'><h2>قالب تازه</h2>"
#                   "<form method='post' action='/%s/template-new' class='row'>"
#                   "<input name='name' placeholder='نام قالب'><button>ساختن</button>"
#                   "</form><p class='muted'>قالب تازه با همهٔ سرویس‌ها ساخته می‌شود؛ "
#                   "بعد تیک‌ها را بردارید. هر قالبِ در حال استفاده یک resolver روی هر "
#                   "رله است، پس حداکثر ۸ تا.</p></div>" % p)
#        return "".join(out)
#
#    def template_editor(self, t):
#        p = CFG["ADMIN_PATH"]
#        back = "<p><a href='/%s/templates'>‹ برگشت به فهرست قالب‌ها</a></p>" % p
#        if t["is_default"]:
#            return (back + "<div class='card'><h2>%s (پیش‌فرض)</h2>"
#                    "<p class='muted'>قالب پیش‌فرض همیشه همهٔ سرویس‌ها را از رله "
#                    "می‌برد، از جمله سرویس‌هایی که بعداً اضافه شوند. برای همین "
#                    "قابل ویرایش نیست — یک قالب تازه بسازید.</p>"
#                    "<p class='muted'>یک استثنا: گروه‌هایی که «پیش‌فرض خاموش» "
#                    "علامت خورده‌اند، حتی در این قالب هم مسیریابی نمی‌شوند. "
#                    "برای روشن کردنشان یک قالب تازه بسازید و آنجا تیکشان بزنید."
#                    "</p></div>"
#                    % html.escape(t["name"]))
#
#        groups = STORE.template_groups(t["id"])
#        off = STORE.template_domains_off(t["id"])
#        out = [back,
#               "<div class='card'><h2>%s</h2>" % html.escape(t["name"]),
#               "<p class='muted'>تیک سرویس یعنی همهٔ دامنه‌هایش از رله می‌رود — "
#               "از جمله دامنه‌هایی که بعداً به آن اضافه شوند. کشو را باز کنید تا "
#               "بین دامنه‌ها یکی‌یکی انتخاب کنید.</p>",
#               "<form method='post' action='/%s/template-save'>"
#               "<input type='hidden' name='id' value='%d'>" % (p, t["id"])]
#
#        for svc in CATALOGUE:
#            for g in svc["groups"]:
#                key = "%s.%s" % (svc["key"], g["key"])
#                on = (svc["key"], g["key"]) in groups
#                label = (svc["label"] if len(svc["groups"]) == 1
#                         else "%s — %s" % (svc["label"], g["label"]))
#                # An opt-in group is one where routing is the wrong default,
#                # not a matter of taste. Say why, next to the tick, rather
#                # than letting it look like every other box on the page.
#                if g.get("opt_in"):
#                    # The reason comes from the group, not from here. These
#                    # are switched off for four different reasons and only one
#                    # of them is matchmaking - a warning that says the same
#                    # thing about all of them is wrong about three.
#                    label += ("<span class='optin'>پیش‌فرض خاموش — %s</span>"
#                              % html.escape(g.get("note") or
#                                            "روشن کردنش چیزی را می‌شکند"))
#                kept = [d for d in g["domains"] if d not in off]
#                # Open the drawer when the operator has already been in here
#                # picking domains, so their exceptions are visible rather than
#                # hidden behind a summary that looks like every other one.
#                partial = on and len(kept) != len(g["domains"])
#                out.append(
#                    "<details class='svc'%s><summary>"
#                    "<label><input type='checkbox' name='g' value='%s'%s> %s</label>"
#                    "<span class='muted count'>%d از %d دامنه</span>"
#                    "<span class='pick'><button type='button' data-all='1'>همه</button>"
#                    "<button type='button' data-all='0'>هیچ‌کدام</button></span>"
#                    "</summary>"
#                    % (" open" if partial else "", html.escape(key),
#                       " checked" if on else "", label,
#                       len(kept) if on else 0, len(g["domains"])))
#                if not g["domains"]:
#                    out.append("<p class='muted'>دامنه‌ای ندارد.</p>")
#                out.append("<div class='doms'>")
#                for d in sorted(g["domains"]):
#                    # A tick on this page means "routed". Inside a group that
#                    # is switched off nothing is routed, so nothing there is
#                    # ticked - otherwise the drawer contradicts the summary
#                    # beside it, which already says 0 of however many.
#                    out.append("<label><input type='checkbox' name='d' value='%s'%s>"
#                               "<span>%s</span></label>"
#                               % (html.escape(d),
#                                  " checked" if on and d not in off else "",
#                                  html.escape(d)))
#                out.append("</div></details>")
#
#        out.append("<div style='margin-top:16px'><button>ذخیره</button> "
#                   "<button class='danger' formaction='/%s/template-delete' "
#                   "formnovalidate>حذف قالب</button></div></form></div>" % p)
#        # Convenience only. Every checkbox above is a plain form control, so
#        # the page works with this script blocked or broken - it just means
#        # ticking five hundred boxes by hand.
#        out.append("""<script>
#(function () {
#  function count(d) {
#    var boxes = d.querySelectorAll('.doms input');
#    var on = d.querySelectorAll('.doms input:checked').length;
#    var g = d.querySelector('summary input[name=g]');
#    var label = d.querySelector('.count');
#    if (label) label.textContent = (g.checked ? on : 0) + ' از ' + boxes.length + ' دامنه';
#  }
#  document.addEventListener('click', function (e) {
#    var b = e.target.closest('.pick button');
#    if (b) {
#      // Inside a <summary>, so the drawer would otherwise open and close
#      // under the operator every time they pressed one of these.
#      e.preventDefault();
#      e.stopPropagation();
#      var d = b.closest('details'), all = b.dataset.all === '1';
#      d.querySelectorAll('.doms input').forEach(function (i) { i.checked = all; });
#      // No domains and the service still ticked would be a tick that routes
#      // nothing, so the two move together.
#      d.querySelector('summary input[name=g]').checked = all;
#      return count(d);
#    }
#    if (e.target.matches('summary input[name=g]')) {
#      e.stopPropagation();
#      var d3 = e.target.closest('details');
#      var boxes = d3.querySelectorAll('.doms input');
#      // Ticking a service means all of it. The drawer is for taking things
#      // out afterwards, not for putting five hundred domains in by hand.
#      if (e.target.checked) {
#        var any = d3.querySelectorAll('.doms input:checked').length;
#        if (!any) boxes.forEach(function (i) { i.checked = true; });
#      } else {
#        boxes.forEach(function (i) { i.checked = false; });
#      }
#      return count(d3);
#    }
#    if (e.target.matches('.doms input')) {
#      var d2 = e.target.closest('details');
#      // Ticking a domain in a service that is switched off is a request for
#      // that service, so switch it on rather than silently ignoring it.
#      if (e.target.checked) d2.querySelector('summary input[name=g]').checked = true;
#      count(d2);
#    }
#  });
#})();
#</script>""")
#        return "".join(out)
#
#    def domains(self):
#        rows = STORE.q("SELECT * FROM custom_domains ORDER BY added_at DESC")
#        shipped = sum(len(g["domains"]) for s in CATALOGUE for g in s["groups"])
#        p = CFG["ADMIN_PATH"]
#        out = ["<div class='card'><h2>دامنه‌های شما (%d)</h2>" % len(rows),
#               "<form method='post' action='/%s/domain-add' class='row' "
#               "style='margin-bottom:14px'>"
#               "<input name='domain' placeholder='example.com' style='min-width:220px'>"
#               "<input name='note' placeholder='یادداشت (اختیاری)'>"
#               "<button>افزودن</button></form>" % p]
#        if rows:
#            out.append("<table><tr><th>دامنه</th><th>یادداشت</th><th>افزوده</th>"
#                       "<th></th></tr>")
#            for r in rows:
#                out.append("<tr><td><code>%s</code></td><td class='muted'>%s</td>"
#                           "<td class='muted'>%s</td>"
#                           "<td><form method='post' action='/%s/domain-del'>"
#                           "<input type='hidden' name='domain' value='%s'>"
#                           "<button class='danger'>حذف</button></form></td></tr>"
#                           % (html.escape(r["domain"]), html.escape(r["note"] or ""),
#                              (r["added_at"] or "")[:10], p, html.escape(r["domain"])))
#            out.append("</table>")
#        out.append("<p class='muted'>زیردامنه‌ها خودکار شامل می‌شوند. این‌ها در سرویس "
#                   "«دامنه‌های دلخواه» جمع می‌شوند، پس در هر قالب می‌شود تیکشان را "
#                   "برداشت. به‌علاوهٔ %d دامنه‌ای که با نصاب می‌آید.</p></div>" % shipped)
#        return "".join(out)
#
#    def settings(self):
#        p = CFG["ADMIN_PATH"]
#        out = []
#        out.append(
#            "<div class='card'><h2>نسخهٔ پشتیبان</h2>"
#            "<p class='muted'>یک فایل sqlite با همهٔ کاربران، آی‌پی‌ها، قالب‌ها، "
#            "تراکنش‌ها و تنظیمات. آمار سلامت سرورها داخلش نیست — حجم زیادی است "
#            "و ارزشی در بازگردانی ندارد.</p>"
#            "<p><a class='dl' href='/%s/backup.db'>دانلود نسخهٔ پشتیبان</a></p>"
#            "<h2 style='margin-top:22px'>بازگردانی</h2>"
#            "<form method='post' action='/%s/restore' enctype='multipart/form-data' "
#            "class='row'><input type='file' name='file' accept='.db' required>"
#            "<button class='ghost'>بررسی فایل</button></form>"
#            "<p class='muted'>فایل اول فقط بررسی و توصیف می‌شود؛ جایگزینی جدا "
#            "تأیید می‌خواهد.</p></div>" % (p, p))
#
#        out.append("<div class='card'><h2>آدرس این پنل</h2>"
#                   "<p class='muted'>همین حالا: <code>https://%s:%s/%s/</code></p>"
#                   "<div class='f'><label>پورت</label>"
#                   "<form method='post' action='/%s/panel-port' class='row'>"
#                   "<input name='port' value='%s' size='6'>"
#                   "<button class='ghost'>تغییر پورت</button></form></div>"
#                   "<div class='f'><label>مسیر مخفی</label>"
#                   "<form method='post' action='/%s/panel-path' class='row'>"
#                   "<input name='path' value='%s' style='min-width:280px'>"
#                   "<button class='ghost'>تغییر مسیر</button>"
#                   "<button class='ghost' name='random' value='1'>مسیر تصادفی</button>"
#                   "</form></div>"
#                   "<div class='msg err'>پورت را که عوض کنید، پنل روی پورت تازه "
#                   "بالا می‌آید — ولی اگر سرور فایروال یا security group دارد "
#                   "(روی AWS، Hetzner و مانندش) باید پورت تازه را <b>اول</b> "
#                   "آنجا باز کنید، وگرنه از بیرون در دسترس نخواهد بود. اگر "
#                   "بیرون ماندید، از روی خود سرور: <code>smartdns-access port "
#                   "9443</code></div></div>"
#                   % (html.escape(panel_host()), html.escape(CFG["ADMIN_PORT"]),
#                      html.escape(CFG["ADMIN_PATH"]),
#                      p, html.escape(CFG["ADMIN_PORT"]),
#                      p, html.escape(CFG["ADMIN_PATH"])))
#
#        out.append("<div class='card'><h2>رمز این پنل</h2>"
#                   "<form method='post' action='/%s/password'>"
#                   "<div class='f'><label>رمز تازه (دست‌کم ۸ نویسه)</label>"
#                   "<input type='password' name='password' style='width:100%%'>"
#                   "</div>"
#                   "<div class='f'><label>تکرار رمز تازه</label>"
#                   "<input type='password' name='again' style='width:100%%'>"
#                   "</div><button>تغییر رمز</button></form>"
#                   "<p class='muted'>رمز ذخیره نمی‌شود، فقط هشش. با تغییر آن "
#                   "همهٔ نشست‌های دیگر بسته می‌شوند.</p></div>" % p)
#        return "".join(out)
#
#    def logs(self):
#        out = []
#        for unit in ("smartdns-panel", "smartdns-admin"):
#            try:
#                txt = subprocess.run(
#                    ["journalctl", "-u", unit, "-n", "60", "--no-pager",
#                     "--output=cat"], capture_output=True, text=True,
#                    timeout=20).stdout
#            except Exception as e:
#                txt = str(e)
#            out.append("<div class='card'><h2>%s</h2><pre style='overflow-x:auto;"
#                       "font-size:12px;color:#9aa4b2;white-space:pre-wrap'>%s</pre>"
#                       "</div>" % (unit, html.escape(txt or "(چیزی نیست)")))
#        return "".join(out)
#
#    # -- actions ----------------------------------------------------------
#    def action(self, rest, params):
#        one = lambda k, d="": self.one(params, k, d)
#
#        if rest == "user-save":
#            uid = int(one("id") or 0)
#            gb = one("quota_gb", "0")
#            days = one("days")
#            try:
#                quota = int(float(gb) * GB) if gb else 0
#            except ValueError:
#                return self.redirect("users?m=!عدد سهمیه درست نیست")
#            # Signing up gets an account, not traffic. Somebody has to decide
#            # this customer may connect, and this form - opening their row and
#            # giving them a plan - is that decision. Read the status before
#            # the writes below, because one of them can change it.
#            was = STORE.one("SELECT status FROM users WHERE id = ?", (uid,))
#            joining = bool(was) and was["status"] == "pending"
#            # Clearing the warning bits matters: a user raised above a
#            # threshold they had already crossed would otherwise never be
#            # warned again.
#            STORE.run("UPDATE users SET quota_bytes = ?, warned = 0,"
#                      " status = CASE WHEN status = 'over_quota' THEN 'active'"
#                      " ELSE status END WHERE id = ?", (quota, uid))
#            if "speed_mb" in params:
#                try:
#                    mb = float(one("speed_mb", "0") or 0)
#                except ValueError:
#                    return self.redirect("users?m=!عدد سرعت درست نیست")
#                if mb < 0:
#                    return self.redirect("users?m=!سرعت منفی نمی‌شود")
#                STORE.run("UPDATE users SET speed_kbps = ? WHERE id = ?",
#                          (int(mb * 1000), uid))
#            if days:
#                try:
#                    count = float(days)
#                except ValueError:
#                    return self.redirect("users?m=!تعداد روز درست نیست")
#                if count < 0:
#                    return self.redirect("users?m=!تعداد روز منفی نمی‌شود")
#                if count == 0:
#                    # No end date at all. The account then ends only when its
#                    # allowance does, which is what an operator means by
#                    # putting zero in a box that everywhere else on this page
#                    # means "no limit".
#                    STORE.run("UPDATE users SET expires_at = NULL,"
#                              " quota_reset_at = NULL, quota_mode = 'oneoff',"
#                              " status = CASE WHEN status = 'expired' THEN 'active'"
#                              " ELSE status END WHERE id = ?", (uid,))
#                    if joining:
#                        STORE.run("UPDATE users SET status = 'active'"
#                                  " WHERE id = ?", (uid,))
#                    return self.redirect(
#                        "users?m=ذخیره شد؛ بدون محدودیت زمانی"
#                        + ("؛ حساب فعال شد" if joining else ""))
#                when = datetime.now(timezone.utc) + timedelta(days=count)
#                stamp = when.isoformat(timespec="seconds")
#                row = STORE.one("SELECT quota_mode FROM users WHERE id = ?", (uid,))
#                if row and row["quota_mode"] == "monthly":
#                    # A renewing plan: the number moves its next reset rather
#                    # than ending it, which is what renewing means.
#                    STORE.run("UPDATE users SET quota_reset_at = ?"
#                              " WHERE id = ?", (stamp, uid))
#                else:
#                    # Everything else gets an end date that many days out, and
#                    # comes back if it had already run out - which is the whole
#                    # reason an operator types in this box. This used to key
#                    # off whether the account already had a date, which worked
#                    # only because every account started as a dated trial.
#                    STORE.run("UPDATE users SET expires_at = ?,"
#                              " status = CASE WHEN status = 'expired' THEN 'active'"
#                              " ELSE status END WHERE id = ?", (stamp, uid))
#            if joining:
#                STORE.run("UPDATE users SET status = 'active' WHERE id = ?",
#                          (uid,))
#                return self.redirect("users?m=ذخیره شد؛ حساب فعال شد")
#            return self.redirect("users?m=ذخیره شد")
#
#        if rest == "receipt-decide":
#            tid = int(one("id") or 0)
#            to = one("to")
#            if to not in ("approved", "rejected"):
#                return self.redirect("receipts?m=!تصمیم نامعتبر")
#            # The image goes with the decision. It was evidence for a judgement
#            # that has now been made, and keeping every customer's bank slip
#            # for ever is a liability rather than a record.
#            STORE.run("UPDATE transactions SET status = ?, decided_at = ?,"
#                      " receipt_blob = NULL WHERE id = ?", (to, now(), tid))
#            return self.redirect(
#                "receipts?m=%s" % ("رسید تأیید شد؛ حالا سهمیه و زمانش را بگذارید"
#                                   if to == "approved" else "رسید رد شد"))
#
#        if rest == "user-status":
#            uid = int(one("id") or 0)
#            to = one("to")
#            if to not in ("active", "suspended"):
#                return self.redirect("users?m=!وضعیت نامعتبر")
#            # Clearing the warning bits on the way back in: an account that
#            # crossed a threshold while blocked would otherwise never warn
#            # again once it is working.
#            STORE.run("UPDATE users SET status = ?, warned = CASE WHEN ? = 'active'"
#                      " THEN 0 ELSE warned END WHERE id = ?", (to, to, uid))
#            return self.redirect(
#                "users?m=%s" % ("کاربر مسدود شد؛ تا ۳۰ ثانیه دیگر قطع می‌شود"
#                                if to == "suspended" else "کاربر برگشت"))
#
#        if rest == "user-reset":
#            uid = int(one("id") or 0)
#            # The kernel counters on the relays are not touched. Usage here is
#            # the growth of those counters since the last sync, so zeroing the
#            # total is enough - the next sync adds only what has happened
#            # since, not the whole counter again.
#            STORE.run("UPDATE users SET used_bytes = 0, warned = 0,"
#                      " status = CASE WHEN status = 'over_quota' THEN 'active'"
#                      " ELSE status END WHERE id = ?", (uid,))
#            return self.redirect("users?m=مصرف صفر شد")
#
#        if rest == "user-template":
#            STORE.run("UPDATE users SET template_id = ? WHERE id = ?",
#                      (int(one("template_id") or 0), int(one("id") or 0)))
#            return self.redirect("users?m=قالب عوض شد؛ تا ۳۰ ثانیه دیگر روی رله‌ها اعمال می‌شود")
#
#        if rest == "template-new":
#            name = one("name")
#            if not name:
#                return self.redirect("templates?m=!نام لازم است")
#            count = STORE.one("SELECT count(*) c FROM templates")["c"]
#            if count >= 8:
#                return self.redirect("templates?m=!سقف ۸ قالب پر است؛ هر قالب یک "
#                                     "resolver روی هر رله است")
#            try:
#                cur = STORE.run("INSERT INTO templates (name, is_default, created_at)"
#                                " VALUES (?, 0, ?)", (name, now()))
#            except sqlite3.IntegrityError:
#                return self.redirect("templates?m=!قالبی با این نام هست")
#            # Everything except the opt-in groups. A new template starting
#            # with those already ticked would be the panel deciding something
#            # it just told the operator was theirs to decide.
#            skipped = 0
#            for svc in CATALOGUE:
#                for g in svc["groups"]:
#                    if g.get("opt_in"):
#                        skipped += 1
#                        continue
#                    STORE.run("INSERT OR IGNORE INTO template_services"
#                              " (template_id, service_key, group_key) VALUES (?,?,?)",
#                              (cur.lastrowid, svc["key"], g["key"]))
#            return self.redirect(
#                "templates?t=%d&m=قالب ساخته شد با همهٔ سرویس‌ها%s"
#                % (cur.lastrowid,
#                   "؛ %d گروهِ «پیش‌فرض خاموش» تیک نخورد" % skipped
#                   if skipped else ""))
#
#        if rest == "template-save":
#            tid = int(one("id") or 0)
#            if STORE.one("SELECT is_default FROM templates WHERE id = ?",
#                         (tid,))["is_default"]:
#                return self.redirect("templates?m=!قالب پیش‌فرض قابل تغییر نیست")
#            wanted = set(params.get("g") or [])
#            # Checkboxes only report what is ticked, so the off-list is worked
#            # out by subtraction: every domain in a routed group that did not
#            # come back.
#            keep = set(params.get("d") or [])
#            STORE.run("DELETE FROM template_services WHERE template_id = ?", (tid,))
#            STORE.run("DELETE FROM template_domains_off WHERE template_id = ?", (tid,))
#            for svc in CATALOGUE:
#                for g in svc["groups"]:
#                    if "%s.%s" % (svc["key"], g["key"]) not in wanted:
#                        continue
#                    STORE.run("INSERT OR IGNORE INTO template_services"
#                              " (template_id, service_key, group_key) VALUES (?,?,?)",
#                              (tid, svc["key"], g["key"]))
#                    # A ticked service with none of its domains ticked is a
#                    # tick that routes nothing, which nobody means. It is what
#                    # the form sends when the helper script is blocked, so
#                    # read it the only way it makes sense: all of them.
#                    picked = keep.intersection(g["domains"]) or set(g["domains"])
#                    for d in g["domains"]:
#                        if d not in picked:
#                            STORE.run("INSERT OR IGNORE INTO template_domains_off"
#                                      " (template_id, domain) VALUES (?, ?)", (tid, d))
#            return self.redirect("templates?t=%d&m=ذخیره شد؛ تا ۳۰ ثانیه دیگر روی "
#                                 "رله‌ها اعمال می‌شود" % tid)
#
#        if rest == "template-delete":
#            tid = int(one("id") or 0)
#            row = STORE.one("SELECT is_default FROM templates WHERE id = ?", (tid,))
#            if not row or row["is_default"]:
#                return self.redirect("templates?m=!قالب پیش‌فرض حذف نمی‌شود")
#            # Move anyone on it back to the default first, so nobody is left
#            # pointing at a template that no longer exists.
#            default = STORE.one("SELECT id FROM templates WHERE is_default = 1")
#            STORE.run("UPDATE users SET template_id = ? WHERE template_id = ?",
#                      (default["id"] if default else None, tid))
#            STORE.run("DELETE FROM template_services WHERE template_id = ?", (tid,))
#            STORE.run("DELETE FROM templates WHERE id = ?", (tid,))
#            return self.redirect("templates?m=قالب حذف شد و کاربرانش به پیش‌فرض برگشتند")
#
#        if rest == "domain-add":
#            raw = one("domain")
#            try:
#                domain = clean_domain(raw)
#            except ValueError as e:
#                return self.redirect("domains?m=!%s" % e)
#            for svc in CATALOGUE:
#                for grp in svc["groups"]:
#                    if domain in grp["domains"]:
#                        return self.redirect(
#                            "domains?m=!%s از قبل در سرویس %s هست"
#                            % (domain, svc["label"]))
#            if STORE.one("SELECT 1 FROM custom_domains WHERE domain = ?", (domain,)):
#                return self.redirect("domains?m=!%s از قبل اضافه شده" % domain)
#            STORE.run("INSERT INTO custom_domains (domain, note, added_at)"
#                      " VALUES (?, ?, ?)", (domain, one("note") or None, now()))
#            return self.redirect("domains?m=%s اضافه شد" % domain)
#
#        if rest == "domain-del":
#            STORE.run("DELETE FROM custom_domains WHERE domain = ?", (one("domain"),))
#            return self.redirect("domains?m=حذف شد")
#
#        if rest == "restore":
#            return self.take_upload()
#
#        if rest == "restore-apply":
#            return self.apply_restore()
#
#        if rest == "restore-cancel":
#            path = PENDING.pop("path", None)
#            PENDING.clear()
#            if path and os.path.exists(path):
#                os.unlink(path)
#            return self.redirect("settings?m=بازگردانی لغو شد")
#
#        if rest == "panel-port":
#            port = one("port")
#            if not port.isdigit() or not 1 <= int(port) <= 65535:
#                return self.redirect("settings?m=!پورت باید عددی بین ۱ تا ۶۵۵۳۵ باشد")
#            if int(port) in RESERVED_PORTS:
#                return self.redirect(
#                    "settings?m=!پورت %s برای %s است"
#                    % (port, RESERVED_PORTS[int(port)]))
#            if port == CFG["ADMIN_PORT"]:
#                return self.redirect("settings?m=همان پورت قبلی است")
#            set_config_key("ADMIN_PORT", port)
#            CFG["ADMIN_PORT"] = port
#            return self.moving_to(port, CFG["ADMIN_PATH"])
#
#        if rest == "panel-path":
#            new = secrets.token_hex(12) if one("random") else one("path")
#            if not re.match(r"^[A-Za-z0-9_-]{8,64}$", new):
#                return self.redirect(
#                    "settings?m=!مسیر باید ۸ تا ۶۴ نویسه از حروف، رقم، - و _ باشد")
#            if new == CFG["ADMIN_PATH"]:
#                return self.redirect("settings?m=همان مسیر قبلی است")
#            set_config_key("ADMIN_PATH", new)
#            CFG["ADMIN_PATH"] = new
#            return self.moving_to(CFG["ADMIN_PORT"], new)
#
#        if rest == "password":
#            new = one("password")
#            # Asked twice, because it cannot be read back to check afterwards
#            # and a typo here locks the operator out of their own panel.
#            if new != one("again"):
#                return self.redirect("settings?m=!دو رمز یکی نیستند")
#            if len(new) < 8:
#                return self.redirect("settings?m=!رمز باید حداقل ۸ نویسه باشد")
#            salt = secrets.token_hex(16)
#            digest = hash_password(new, salt)
#            set_config_key("ADMIN_SALT", salt)
#            set_config_key("ADMIN_HASH", digest)
#            CFG["ADMIN_SALT"], CFG["ADMIN_HASH"] = salt, digest
#            # Everyone else holding a session was authenticated with the old
#            # password; a password change should end those.
#            STORE.run("DELETE FROM admin_sessions WHERE token != ?",
#                      (self.session_token(),))
#            return self.redirect("settings?m=رمز عوض شد")
#
#        return self.lost()
#
#
#DOMAIN_RE = __import__("re").compile(
#    r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
#FORBIDDEN = ("localhost", "local", "internal", "arpa", "telegram.org",
#             "t.me", "telegram.me")
#
#
#def clean_domain(raw):
#    """Same normalisation the bot does, so a domain added here and one added
#    there end up identical rather than as two rows differing by a www."""
#    import re
#    d = (raw or "").strip().lower()
#    d = re.sub(r"^[a-z]+://", "", d)
#    d = d.split("/")[0].split("?")[0].split("@")[-1].split(":")[0].strip(".")
#    if not d:
#        raise ValueError("خالی است")
#    if not DOMAIN_RE.match(d):
#        raise ValueError("قالب دامنه درست نیست")
#    if any(d == f or d.endswith("." + f) for f in FORBIDDEN):
#        raise ValueError("این دامنه را نمی‌شود مسیر داد")
#    return d
#
#
#def set_config_key(key, value):
#    """Rewrite one key in admin.env, leaving the rest of the file alone."""
#    lines = []
#    if os.path.exists(CONFIG):
#        with open(CONFIG) as fh:
#            lines = [l for l in fh.read().split("\n") if not l.startswith(key + "=")]
#    lines = [l for l in lines if l.strip()]
#    lines.append("%s=%s" % (key, value))
#    tmp = CONFIG + ".tmp"
#    with open(tmp, "w") as fh:
#        fh.write("\n".join(lines) + "\n")
#    os.chmod(tmp, 0o600)
#    os.replace(tmp, CONFIG)
#
#
#def main():
#    global STORE, CFG, CATALOGUE
#    CFG = load_config()
#    CATALOGUE = load_catalogue()
#    STORE = Store(DB)
#
#    port = int(CFG["ADMIN_PORT"])
#    httpd = http.server.ThreadingHTTPServer(("0.0.0.0", port), Admin)
#    cert = CFG.get("ADMIN_CERT")
#    key = CFG.get("ADMIN_KEY")
#    if cert and key and os.path.exists(cert):
#        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
#        ctx.load_cert_chain(cert, key)
#        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
#        scheme = "https"
#    else:
#        # Refuse rather than silently serve a login form in the clear: the
#        # password would cross the network readable by anyone on the path.
#        sys.exit("no certificate at %s - refusing to serve the panel over plain "
#                 "http" % cert)
#    print("admin panel up on %s://0.0.0.0:%d/%s/"
#          % (scheme, port, CFG["ADMIN_PATH"]), flush=True)
#    httpd.serve_forever()
#
#
#if __name__ == "__main__":
#    main()
#__END_ADMIN__

#__BEGIN_ADMIN_SERVICE__
#[Unit]
#Description=Smart DNS admin web panel
#After=network-online.target smartdns-panel.service
#
#[Service]
#Type=simple
#ExecStart=/usr/local/bin/smartdns-admin
#Restart=always
#RestartSec=10
## Reads the certificate and writes admin.env when the password changes, so it
## needs root - but nothing else on the box.
#NoNewPrivileges=yes
#ProtectHome=yes
#PrivateTmp=yes
#
#[Install]
#WantedBy=multi-user.target
#__END_ADMIN_SERVICE__

#__BEGIN_SMARTDNS_ACCESS__
##!/bin/bash
## smartdns-access - change how the admin panel is reached.
##
## usage: smartdns-access                    show the address it answers on
##        smartdns-access port <number>      move it to another port
##        smartdns-access path [new]         change the secret path, or roll one
##        smartdns-access password [new]     set a new password
##        smartdns-access rotate             new path and new password at once
##
## Three things stand in front of the panel and only one of them is a secret in
## the cryptographic sense:
##
##   the port    keeps it out of the way of casual scanning, nothing more
##   the path    an unguessable URL - it is a secret, but it travels in every
##               request line and lands in any proxy log along the way
##   the password the actual authentication
##
## So this can change all three, and the password is the one that matters. It
## is never stored: only a salted hash goes into admin.env, which is why a
## forgotten password is replaced rather than recovered.
#set -uo pipefail
#export PATH="$PATH:/usr/sbin:/sbin"
#
#CONF=/etc/smart-dns/admin.env
#UNIT=smartdns-admin.service
#
#R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
#[ -t 1 ] || { R=; G=; Y=; B=; N=; }
#die() { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
#
#[ "$(id -u)" = 0 ] || die "run as root"
#[ -f "$CONF" ] || die "$CONF is missing - this machine has no admin panel.
#    It is set up on the exit node, by the installer, once the machine has a
#    domain and a certificate."
#
#get() { sed -n "s/^$1=//p" "$CONF" | head -1; }
#
#set_key() {
#    local key="$1" value="$2" tmp
#    tmp="$(mktemp)"
#    grep -v "^${key}=" "$CONF" > "$tmp" 2>/dev/null || true
#    printf '%s=%s\n' "$key" "$value" >> "$tmp"
#    # Copy rather than move: the file is mode 600 and owned by root, and a
#    # move from /tmp would bring the temporary file's permissions with it.
#    cat "$tmp" > "$CONF"
#    rm -f "$tmp"
#    chmod 600 "$CONF"
#}
#
#hash_password() {
#    ADMIN_PASS="$1" ADMIN_SALT="$2" python3 -c '
#import hashlib, os
#print(hashlib.pbkdf2_hmac("sha256", os.environ["ADMIN_PASS"].encode(),
#                          bytes.fromhex(os.environ["ADMIN_SALT"]), 200000).hex())'
#}
#
#domain() {
#    # Whatever the certificate is for. The panel answers on any address the
#    # machine has, but only this name matches the certificate, so it is the
#    # only one worth printing.
#    local d
#    d="$(sed -n 's|^ADMIN_CERT=/etc/letsencrypt/live/\([^/]*\)/.*|\1|p' "$CONF" | head -1)"
#    [ -n "$d" ] || d="$(hostname -I 2>/dev/null | awk '{print $1}')"
#    printf '%s' "${d:-this-server}"
#}
#
#show() {
#    printf '\n    %sAdmin panel%s\n\n        https://%s:%s/%s/\n\n' \
#        "$B" "$N" "$(domain)" "$(get ADMIN_PORT)" "$(get ADMIN_PATH)"
#    printf '    The password is not stored, only a hash of it. If it is lost,\n'
#    printf '    set a new one:  smartdns-access password\n\n'
#}
#
#restart() {
#    systemctl restart "$UNIT" 2>/dev/null
#    sleep 2
#    if systemctl is-active --quiet "$UNIT"; then
#        printf '%s    panel restarted%s\n' "$G" "$N"
#    else
#        printf '%s    the panel did not come back - journalctl -u %s%s\n' \
#            "$Y" "$UNIT" "$N"
#    fi
#}
#
#case "${1:-show}" in
#show|"")
#    show
#    ;;
#
#port)
#    new="${2:-}"
#    case "$new" in
#        ""|*[!0-9]*) die "usage: smartdns-access port <number>" ;;
#    esac
#    [ "$new" -ge 1 ] && [ "$new" -le 65535 ] || die "a port is 1-65535"
#    # These belong to the service itself. Moving the panel onto one of them
#    # would take down the thing it is meant to administer.
#    case "$new" in
#        53|80|443) die "port $new is the service's own - pick another" ;;
#        8443) die "port 8443 is the sync API the relays talk to" ;;
#        22) die "port 22 is ssh" ;;
#    esac
#    old="$(get ADMIN_PORT)"
#    if [ "$new" != "$old" ] && ss -tlnH "sport = :$new" 2>/dev/null | grep -q .; then
#        die "something else is already listening on $new"
#    fi
#    set_key ADMIN_PORT "$new"
#    printf '    port %s -> %s\n' "$old" "$new"
#    restart
#    show
#    ;;
#
#path)
#    new="${2:-}"
#    if [ -z "$new" ]; then
#        new="$(openssl rand -hex 12)"
#    else
#        case "$new" in
#            */*|*' '*|*'?'*|*'#'*) die "a path is one segment: letters, digits, - and _" ;;
#            *[!A-Za-z0-9_-]*) die "use only letters, digits, - and _" ;;
#        esac
#        [ "${#new}" -ge 8 ] || die "too short to be unguessable - use 8 or more"
#    fi
#    set_key ADMIN_PATH "$new"
#    printf '    the old address stops working now.\n'
#    restart
#    show
#    ;;
#
#password)
#    new="${2:-}"
#    if [ -z "$new" ]; then
#        # -s so it is not echoed, and asked twice because it cannot be read
#        # back afterwards to check.
#        printf '  new password (8 or more, not shown as you type): '
#        read -rs new; printf '\n'
#        printf '  again: '
#        read -rs again; printf '\n'
#        [ "$new" = "$again" ] || die "they did not match - nothing changed"
#    fi
#    [ "${#new}" -ge 8 ] || die "use 8 characters or more"
#    salt="$(openssl rand -hex 16)"
#    hash="$(hash_password "$new" "$salt")" || die "could not hash the password"
#    [ -n "$hash" ] || die "could not hash the password"
#    set_key ADMIN_SALT "$salt"
#    set_key ADMIN_HASH "$hash"
#    printf '    password changed. Everyone signed in is signed out.\n'
#    # Sessions live in the panel's memory, so restarting is what ends them -
#    # which is the point of changing a password.
#    restart
#    ;;
#
#rotate)
#    "$0" path >/dev/null
#    "$0" password "${2:-}"
#    show
#    ;;
#
#*)
#    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
#    exit 1
#    ;;
#esac
#__END_SMARTDNS_ACCESS__

#__BEGIN_EPIC_PIN__
##!/usr/bin/env python3
#"""Pin Epic's backend names to the addresses that are actually reachable here.
#
#Epic's game backend must NOT be routed through the exit: matchmaking has to come
#from the same address the console later plays from, or the game server ignores
#the gameplay packets. See docs/fortnite-udp.md.
#
#But letting it resolve normally has its own failure. Epic round-robins each name
#across many addresses and a few are unreachable from Iran - one in thirty-three
#when sampled. A console that draws a dead one stalls on that service, which is
#why Fortnite worked on some attempts and not others.
#
#So pin each name to addresses verified reachable. Those address= entries are more
#specific than the server= bypass rule, so dnsmasq prefers them.
#
#The important part is knowing when NOT to act. Epic's address sets rotate
#constantly, so the first version of this rewrote the file on nearly every run -
#and since dnsmasq cannot re-read its config without a restart, that meant
#restarting the resolver every ten minutes, all day. Each restart is a brief DNS
#outage and a full cache flush, which is its own source of exactly the
#intermittent breakage this script exists to prevent. It made a day of test
#results untrustworthy.
#
#So: probe only the addresses already pinned. If they all still answer, do nothing
#at all. Re-resolve and rewrite only when a pinned address has actually died, or
#when there are no pins yet. In the steady state this touches nothing.
#"""
#import concurrent.futures as cf
#import os
#import socket
#import subprocess
#import sys
#
#CONF = "/etc/dnsmasq.d/epic-pins.conf"
#RESOLVERS = ("1.1.1.1", "8.8.8.8")
#PROBE_PORT = 443
#PROBE_TIMEOUT = 2.5
#
#HOSTS = [
#    "account-public-service-prod.ol.epicgames.com",
#    "datarouter.ol.epicgames.com",
#    "launcher-public-service-prod06.ol.epicgames.com",
#    "links-public-service-live.ol.epicgames.com",
#    "events-public-service-live.ol.epicgames.com",
#    "datastorage-public-service-live.ol.epicgames.com",
#    "data-asset-directory-public-service-prod.ol.epicgames.com",
#    "fortnitecontent-website-prod07.ol.epicgames.com",
#    "fortnite-public-service-prod11.ol.epicgames.com",
#    "mcp-gc.live.fngw.ol.epicgames.com",
#    "gc.svc.live.fngw.ol.epicgames.com",
#    "ds.svc.live.fngw.ol.epicgames.com",
#    "fngw-svc-ds-livefn.ol.epicgames.com",
#    "fn-service-habanero-live-public.ogs.live.on.epicgames.com",
#    "fn-service-discovery-live-public.ogs.live.on.epicgames.com",
#    "prm-dialogue-public-api-prod.edea.live.use1a.on.epicgames.com",
#]
#
#
#def resolve(host):
#    for r in RESOLVERS:
#        try:
#            out = subprocess.run(
#                ["dig", "+short", "+time=3", "+tries=1", "@" + r, host, "A"],
#                capture_output=True, text=True, timeout=8).stdout
#        except Exception:
#            continue
#        ips = [l.strip() for l in out.splitlines()
#               if l.strip() and l.strip()[0].isdigit() and l.count(".") == 3]
#        if ips:
#            return ips
#    return []
#
#
#def alive(ip):
#    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
#    s.settimeout(PROBE_TIMEOUT)
#    try:
#        s.connect((ip, PROBE_PORT))
#        return True
#    except Exception:
#        return False
#    finally:
#        s.close()
#
#
#def read_pins():
#    """host -> [addresses], from the file we last wrote."""
#    pins = {}
#    if not os.path.exists(CONF):
#        return pins
#    for line in open(CONF):
#        line = line.strip()
#        if not line.startswith("address=/"):
#            continue
#        parts = line.split("/")
#        if len(parts) >= 3:
#            pins.setdefault(parts[1], []).append(parts[2])
#    return pins
#
#
#def main():
#    pins = read_pins()
#
#    # Steady state: everything already pinned still answers, so leave the
#    # resolver alone. Restarting it to write a file that differs only by Epic's
#    # rotation is how this script used to cause the problem it prevents.
#    if pins and set(pins) == set(HOSTS):
#        addrs = sorted({a for v in pins.values() for a in v})
#        with cf.ThreadPoolExecutor(max_workers=16) as ex:
#            health = dict(zip(addrs, ex.map(alive, addrs)))
#        dead = [a for a in addrs if not health[a]]
#        if not dead:
#            print("epic-pin: all %d pinned addresses still healthy, nothing to do"
#                  % len(addrs))
#            return 0
#        print("epic-pin: %d pinned address(es) died (%s), refreshing"
#              % (len(dead), ", ".join(dead[:4])))
#
#    lines = ["# generated by epic-pin - do not edit, changes are overwritten",
#             "# only addresses that answered on tcp/%d from this host" % PROBE_PORT,
#             ""]
#    total = good = 0
#    with cf.ThreadPoolExecutor(max_workers=16) as ex:
#        resolved = dict(zip(HOSTS, ex.map(resolve, HOSTS)))
#        every = sorted({ip for ips in resolved.values() for ip in ips})
#        health = dict(zip(every, ex.map(alive, every)))
#
#    for host in HOSTS:
#        ips = [ip for ip in resolved.get(host, []) if health.get(ip)]
#        total += len(resolved.get(host, []))
#        good += len(ips)
#        if not ips:
#            # Nothing verified: say nothing and let the bypass resolve it live.
#            # A wrong pin is worse than no pin.
#            continue
#        for ip in ips:
#            lines.append("address=/%s/%s" % (host, ip))
#
#    with open(CONF, "w") as fh:
#        fh.write("\n".join(lines) + "\n")
#
#    check = subprocess.run(["dnsmasq", "--test", "-C", "/etc/dnsmasq.conf"],
#                           capture_output=True, text=True)
#    if check.returncode != 0:
#        os.remove(CONF)
#        print("epic-pin: dnsmasq rejected the file, removed it\n" + check.stderr,
#              file=sys.stderr)
#        return 1
#
#    # A reload only clears the cache; dnsmasq does not re-read /etc/dnsmasq.d
#    # without a restart. That is why the syntax check above runs first, and why
#    # reaching this line at all should be rare.
#    subprocess.run(["systemctl", "restart", "dnsmasq"], check=False)
#    print("epic-pin: rewrote pins and restarted dnsmasq (%d/%d healthy)"
#          % (good, total))
#    return 0
#
#
#if __name__ == "__main__":
#    sys.exit(main())
#__END_EPIC_PIN__

#__BEGIN_EPIC_PIN_SERVICE__
#[Unit]
#Description=Pin Epic backend names to reachable addresses
#After=network-online.target dnsmasq.service
#Wants=network-online.target
#
#[Service]
#Type=oneshot
#ExecStart=/usr/local/bin/epic-pin
#TimeoutStartSec=120
#__END_EPIC_PIN_SERVICE__

#__BEGIN_EPIC_PIN_TIMER__
#[Unit]
#Description=Refresh Epic backend address pins
#
#[Timer]
## Epic's address sets rotate, and a pin that has gone stale is worse than none,
## so refresh often and start shortly after boot rather than waiting a full cycle.
#OnBootSec=2min
#OnUnitActiveSec=10min
#AccuracySec=30s
#
#[Install]
#WantedBy=timers.target
#__END_EPIC_PIN_TIMER__

#__BEGIN_DOMAINS__
#3docean.net
#accounts.google.com
#acm.org
#activision.com
#adobe.com
#adobelogin.com
#ads.google.com
#adservice.google.com
#ai.google
#aistudio.google.com
#aka.ms
#algolia.com
#algolia.net
#altera.com
#amd.com
#amp.dev
#analytics.google.com
#android.com
#ant.design
#anthropic.com
#anydesk.com
#apache.org
#apexlegends.com
#apis.google.com
#appengine.google.com
#apple.com
#apps.admob.com
#appspot.com
#arcgis.com
#archive.ubuntu.com
#arduino.cc
#arxiv.org
#asana.com
#atlassian.com
#atlassian.net
#aws.amazon.com
#b4x.com
#baeldung.com
#battle.net
#battlecode.org
#battlefield.com
#beans.org
#bethesda.net
#bintray.com
#bioware.com
#bit.dev
#bitbucket.org
#bitsrc.io
#bitvise.com
#blizzard.com
#bluemix.net
#books.google.com
#bootstrapcdn.com
#bootswatch.com
#branch.io
#bugsnag.com
#bun.sh
#business.google.com
#c9.io
#caddy.com
#caddyserver.com
#callofduty.com
#canva.com
#centos.org
#chatgpt.com
#chocolatey.org
#cisco.com
#clamav.net
#classroom.google.com
#claude.ai
#clients.google.com
#clients2.google.com
#clients6.google.com
#cljdoc.org
#cloud.google.com
#cloudera.com
#cloudflare.com
#cloudfront.net
#cocalc.com
#code.google.com
#code.visualstudio.com
#codecanyon.net
#codecov.io
#codeium.com
#codesandbox.io
#codex.cs.yale.edu
#coinbase.com
#colab.research.google.com
#count.ly
#coursehero.com
#coursera-apps.org
#coursera.com
#coursera.org
#cp.maxcdn.com
#crashlytics.com
#crates.io
#criteriongames.com
#csb.app
#curd.io
#cursor.com
#cursor.sh
#dartlang.org
#datacamp.com
#deepmind.google
#deepseek.com
#dell.com
#demandbase.com
#deno.land
#design.google.com
#developer.chrome.com
#developer.google.com
#developer.samsung.com
#developers.google.com
#dice.se
#digikey.com
#digitalocean.com
#discord.com
#discord.gg
#discordapp.com
#discordapp.net
#dl-ssl.google.com
#dl.google.com
#dns.google.com
#docker.com
#docker.io
#docs.datastax.com
#domains.google.com
#dotnet.microsoft.com
#doubleclick.net
#doubleclickbygoogle.com
#download.01.org
#download.virtualbox.org
#ea.com
#eaaccess.com
#eaassets-a.akamaihd.net
#eacdn.com
#eamobile.com
#eaplay.com
#easports.com
#edgesuite.net
#edx.org
#elastic.co
#element14.com
#en25.com
#enterprisedb.com
#envato-static.com
#envato.com
#epicgames.com
#es.io
#eslint.org
#espressif.com
#events.google.com
#explainshell.com
#expo.io
#expressjs.com
#fabric.io
#faceit.com
#fbsbx.com
#fcmobile.com
#fiber.google.com
#figma.com
#firebase.com
#firebase.google.com
#flurry.com
#flutter.dev
#flutter.io
#fluttercrashcourse.com
#flutterlearn.com
#fly.io
#fodev.org
#forums.cpanel.net
#freecodecamp.org
#frostbite.com
#fsdn.com
#gallery.io
#gallerycdn.vsassets.io
#gamepass.com
#garena.com
#gcr.io
#geforce.com
#gemini.google.com
#getbootstrap.com
#getcaddy.com
#ghcr.io
#github.com
#githubapp.com
#githubassets.com
#githubusercontent.com
#gitkraken.com
#gitlab-static.net
#gitlab.com
#gitlab.io
#gitpod.io
#go.dev
#goanimate.com
#godbolt.org
#godoc.org
#gog.com
#golang.org
#google-analytics.com
#google.ai
#googleadservices.com
#googleapis.com
#googleblog.com
#googlesource.com
#googletagmanager.com
#googletagservices.com
#googleusercontent.com
#gopkg.in
#grabcad.com
#gradle.org
#grafana.com
#graphicriver.net
#graphql.org
#gravatar.com
#groq.com
#gstatic.com
#hackerrank.com
#hashicorp.com
#helm.sh
#heroku.com
#hetzner.com
#hf.co
#hoyoverse.com
#huggingface.co
#humblebundle.com
#hyper.is
#i.stack.imgur.com
#i18next.com
#ibm.com
#ieee.org
#incredibuild.com
#intel.com
#invis.io
#issuetracker.google.com
#itch.io
#jaspersoft.com
#java.com
#javacardos.com
#jenkins-ci.org
#jenkins.org
#jenkov.com
#jetbrains.com
#jfrog.io
#jfrog.org
#jhipster.tech
#jitpack.io
#jitsi.org
#jungle.net
#justpaste.it
#jwplayer.com
#k8s.io
#kaggle.com
#kaggle.net
#kaggleusercontent.com
#khanacademy.org
#krafton.com
#kubernetes.io
#labix.org
#labs.google
#laravel.com
#launchpad.net
#leagueoflegends.com
#learn.microsoft.com
#lenovo.com
#libraries.io
#lightstep.com
#linear.app
#linode.com
#livefyre.com
#maas.io
#mailgun.com
#marketingplantform.google.com
#marketplace.visualstudio.com
#material.io
#mathworks.com
#maven.google.com
#maven.org
#maxis.com
#mbed.com
#medium.com
#metasploit.com
#microchip.com
#mihoyo.com
#minecraft.net
#minecraftservices.com
#miro.com
#mistral.ai
#mit.edu
#mojang.com
#mongodb.com
#mongodb.org
#mp.microsoft.com
#mybridge.co
#myfonts.net
#mysql.com
#nativescript.org
#needforspeed.com
#netflix.com
#netlify.app
#netlify.com
#newrelic.com
#nextjs.org
#nflxext.com
#nflximg.net
#nflxvideo.net
#nginx.com
#ni.com
#nintendo.com
#nintendo.net
#nirsoft.net
#nodejs.org
#notebooklm.google.com
#notion.so
#npmjs.com
#npmjs.org
#nuget.org
#nvidia.com
#oaistatic.com
#oaiusercontent.com
#ollama.com
#openai.com
#openrouter.ai
#optimize.google.com
#optimizely.com
#oracle.com
#origin.com
#overleaf.com
#packagesource.com
#packagist.org
#packtpub.com
#parsely.com
#payments.google.com
#paypal.com
#paypalobjects.com
#perplexity.ai
#photodune.net
#php.net
#piles.overleaf.com
#pkg.go.dev
#play.google.com
#playstation.com
#playstation.net
#pnpm.io
#polymer-project.org
#popcap.com
#postman.com
#proandroiddev.com
#pscdn.co
#pubg.com
#pypi.org
#python.org
#qt.io
#qualcomm.com
#quay.io
#railway.app
#rapid7.com
#raspberrypi.com
#rbxcdn.com
#reactjs.org
#realm.io
#registry.k8s.io
#releases.hashicorp.com
#render.com
#replit.com
#researchgate.net
#respawn.com
#riotgames.com
#roblox.com
#rockstargames.com
#ruby-doc.org
#rubygems.org
#rust-lang.org
#salesforce.com
#scdn.co
#schema.org
#sciencedirect.com
#seleniumhq.org
#sendgrid.com
#sentry.io
#serialport.io
#serverfault.com
#slack-edge.com
#slack.com
#socket.io
#softlayer.com
#softonic.com
#sonarsource.com
#sonatype.org
#sonyentertainmentnetwork.com
#sparkjava.com
#spiceworks.com
#splunk.com
#spotify.com
#spring.io
#springer.com
#sstatic.net
#st.com
#stackexchange.com
#stackoverflow.com
#steamcommunity.com
#steamcontent.com
#steampowered.com
#steamstatic.com
#storage.googleapis.com
#stripe.com
#sun.com
#supabase.com
#supercell.com
#superuser.com
#surveys.google.com
#swaggerhub.com
#swift.org
#swtor.com
#symfony.com
#tagmanager.google.com
#take2games.com
#teamtreehouse.com
#teamviewer.com
#telerik.com
#tensorflow.org
#terraform.io
#themeforest.net
#thesims.com
#ti.com
#tinyjpg.com
#tinypng.com
#together.ai
#toggl.com
#traviscistatus.com
#trello.com
#ttvnw.net
#twitch.tv
#ubi.com
#ubisoft.com
#udemy.com
#udemycdn-a.com
#udemycdn.com
#unity.com
#unity3d.com
#unrealengine.com
#unsplash.com
#upwork.com
#vagrantup.com
#valorant.com
#valvesoftware.com
#vercel.app
#vercel.com
#videohive.net
#virtualbox.org
#visualstudio.microsoft.com
#vmcdn.com
#vmware.com
#vscode-cdn.net
#vscode.dev
#vuejs.org
#vuetifyjs.com
#vuforia.com
#web.dev
#wikia.com
#windsurf.com
#withgoogle.com
#wolframalpha.com
#wpastra.com
#x.ai
#xbox.com
#xboxlive.com
#xilinx.com
#yarnpkg.com
#yarnpkg.org
#zeit.co
#zeplin.io
#zoom.us
#__END_DOMAINS__

#__BEGIN_SERVICES__
#{
#  "services": [
#    {
#      "key": "playstation",
#      "label": "PlayStation",
#      "groups": [
#        {
#          "key": "online",
#          "label": "فروشگاه، اکانت و بازی آنلاین",
#          "domains": [
#            "playstation.com",
#            "playstation.net",
#            "pscdn.co",
#            "sonyentertainmentnetwork.com"
#          ]
#        },
#        {
#          "key": "download",
#          "label": "دانلود بازی",
#          "domains": [
#            "gst.prod.dl.playstation.net",
#            "ps5cel.np.dl.playstation.net",
#            "uef.np.dl.playstation.net",
#            "zeus.dl.playstation.net"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "xbox",
#      "label": "Xbox",
#      "groups": [
#        {
#          "key": "online",
#          "label": "فروشگاه، اکانت و بازی آنلاین",
#          "domains": [
#            "edgesuite.net",
#            "gamepass.com",
#            "mp.microsoft.com",
#            "xbox.com",
#            "xboxlive.com"
#          ]
#        },
#        {
#          "key": "download",
#          "label": "دانلود بازی",
#          "domains": [
#            "assets1.xboxlive.com",
#            "dl.delivery.mp.microsoft.com",
#            "dlassets.xboxlive.com",
#            "xvcf1.xboxlive.com",
#            "xvcf2.xboxlive.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "nintendo",
#      "label": "Nintendo",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "nintendo.com",
#            "nintendo.net"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "steam",
#      "label": "Steam",
#      "groups": [
#        {
#          "key": "main",
#          "label": "فروشگاه و انجمن",
#          "domains": [
#            "steamcommunity.com",
#            "steampowered.com",
#            "steamstatic.com",
#            "valvesoftware.com"
#          ]
#        },
#        {
#          "key": "download",
#          "label": "دانلود بازی",
#          "domains": [
#            "steamcontent.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "epic",
#      "label": "Epic Games",
#      "groups": [
#        {
#          "key": "main",
#          "label": "فروشگاه، لانچر و اکانت",
#          "domains": [
#            "epicgames.com",
#            "unrealengine.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "ea",
#      "label": "EA",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "apexlegends.com",
#            "battlefield.com",
#            "bioware.com",
#            "criteriongames.com",
#            "dice.se",
#            "ea.com",
#            "eaaccess.com",
#            "eaassets-a.akamaihd.net",
#            "eacdn.com",
#            "eamobile.com",
#            "eaplay.com",
#            "easports.com",
#            "fcmobile.com",
#            "frostbite.com",
#            "maxis.com",
#            "needforspeed.com",
#            "origin.com",
#            "popcap.com",
#            "respawn.com",
#            "swtor.com",
#            "thesims.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "blizzard",
#      "label": "Blizzard / Activision",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "activision.com",
#            "battle.net",
#            "blizzard.com",
#            "callofduty.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "ubisoft",
#      "label": "Ubisoft",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "ubi.com",
#            "ubisoft.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "riot",
#      "label": "Riot Games",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "leagueoflegends.com",
#            "riotgames.com",
#            "valorant.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "rockstar",
#      "label": "Rockstar",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "rockstargames.com",
#            "take2games.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "bethesda",
#      "label": "Bethesda",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "bethesda.net"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "gog",
#      "label": "GOG / itch.io",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "gog.com",
#            "humblebundle.com",
#            "itch.io"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "roblox",
#      "label": "Roblox",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "rbxcdn.com",
#            "roblox.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "minecraft",
#      "label": "Minecraft",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "minecraft.net",
#            "minecraftservices.com",
#            "mojang.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "othergames",
#      "label": "بازی‌های دیگر",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "battlecode.org",
#            "faceit.com",
#            "garena.com",
#            "hoyoverse.com",
#            "incredibuild.com",
#            "krafton.com",
#            "mihoyo.com",
#            "pubg.com",
#            "supercell.com",
#            "unity.com",
#            "unity3d.com",
#            "vuforia.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "netflix",
#      "label": "Netflix",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "netflix.com",
#            "nflxext.com",
#            "nflximg.net",
#            "nflxvideo.net"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "twitch",
#      "label": "Twitch",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "ttvnw.net",
#            "twitch.tv"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "spotify",
#      "label": "Spotify",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "scdn.co",
#            "spotify.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "openai",
#      "label": "OpenAI / ChatGPT",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "chatgpt.com",
#            "oaistatic.com",
#            "oaiusercontent.com",
#            "openai.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "anthropic",
#      "label": "Claude",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "anthropic.com",
#            "claude.ai"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "otherai",
#      "label": "هوش مصنوعی دیگر",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "codeium.com",
#            "cursor.com",
#            "cursor.sh",
#            "deepmind.google",
#            "deepseek.com",
#            "groq.com",
#            "hf.co",
#            "huggingface.co",
#            "kaggle.com",
#            "kaggle.net",
#            "kaggleusercontent.com",
#            "mistral.ai",
#            "ollama.com",
#            "openrouter.ai",
#            "perplexity.ai",
#            "tensorflow.org",
#            "together.ai",
#            "windsurf.com",
#            "x.ai"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "github",
#      "label": "GitHub",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "github.com",
#            "githubapp.com",
#            "githubassets.com",
#            "githubusercontent.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "gitlab",
#      "label": "GitLab / Bitbucket",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "bitbucket.org",
#            "gitkraken.com",
#            "gitlab-static.net",
#            "gitlab.com",
#            "gitlab.io",
#            "gitpod.io"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "docker",
#      "label": "Docker / Kubernetes",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "docker.com",
#            "docker.io",
#            "gcr.io",
#            "ghcr.io",
#            "helm.sh",
#            "k8s.io",
#            "kubernetes.io",
#            "quay.io",
#            "registry.k8s.io"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "packages",
#      "label": "مخازن پکیج",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "archive.ubuntu.com",
#            "bintray.com",
#            "centos.org",
#            "chocolatey.org",
#            "crates.io",
#            "fsdn.com",
#            "go.dev",
#            "godoc.org",
#            "golang.org",
#            "gopkg.in",
#            "gradle.org",
#            "jfrog.io",
#            "jfrog.org",
#            "jitpack.io",
#            "labix.org",
#            "launchpad.net",
#            "libraries.io",
#            "maas.io",
#            "maven.google.com",
#            "maven.org",
#            "npmjs.com",
#            "npmjs.org",
#            "nuget.org",
#            "packagesource.com",
#            "packagist.org",
#            "pkg.go.dev",
#            "pnpm.io",
#            "pypi.org",
#            "rubygems.org",
#            "sonatype.org",
#            "yarnpkg.com",
#            "yarnpkg.org"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "microsoft",
#      "label": "Microsoft / VS Code",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "aka.ms",
#            "code.visualstudio.com",
#            "dotnet.microsoft.com",
#            "gallerycdn.vsassets.io",
#            "learn.microsoft.com",
#            "marketplace.visualstudio.com",
#            "visualstudio.microsoft.com",
#            "vscode-cdn.net",
#            "vscode.dev"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "jetbrains",
#      "label": "JetBrains",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "jetbrains.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "adobe",
#      "label": "Adobe",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "adobe.com",
#            "adobelogin.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "nvidia",
#      "label": "NVIDIA",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "geforce.com",
#            "nvidia.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "apple",
#      "label": "Apple",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "apple.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "google",
#      "label": "Google",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "accounts.google.com",
#            "ads.google.com",
#            "adservice.google.com",
#            "ai.google",
#            "aistudio.google.com",
#            "analytics.google.com",
#            "apis.google.com",
#            "appengine.google.com",
#            "apps.admob.com",
#            "books.google.com",
#            "business.google.com",
#            "classroom.google.com",
#            "clients.google.com",
#            "clients2.google.com",
#            "clients6.google.com",
#            "cloud.google.com",
#            "code.google.com",
#            "colab.research.google.com",
#            "design.google.com",
#            "developer.google.com",
#            "developers.google.com",
#            "dl-ssl.google.com",
#            "dl.google.com",
#            "dns.google.com",
#            "domains.google.com",
#            "doubleclick.net",
#            "doubleclickbygoogle.com",
#            "events.google.com",
#            "fiber.google.com",
#            "firebase.google.com",
#            "gemini.google.com",
#            "google-analytics.com",
#            "google.ai",
#            "googleadservices.com",
#            "googleapis.com",
#            "googleblog.com",
#            "googlesource.com",
#            "googletagmanager.com",
#            "googletagservices.com",
#            "googleusercontent.com",
#            "gstatic.com",
#            "issuetracker.google.com",
#            "labs.google",
#            "marketingplantform.google.com",
#            "notebooklm.google.com",
#            "optimize.google.com",
#            "payments.google.com",
#            "play.google.com",
#            "storage.googleapis.com",
#            "surveys.google.com",
#            "tagmanager.google.com",
#            "withgoogle.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "discord",
#      "label": "Discord",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "discord.com",
#            "discord.gg",
#            "discordapp.com",
#            "discordapp.net"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "slackzoom",
#      "label": "Slack / Zoom / Teams",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "jitsi.org",
#            "slack-edge.com",
#            "slack.com",
#            "zoom.us"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "figma",
#      "label": "Figma / Canva / Notion",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "asana.com",
#            "canva.com",
#            "figma.com",
#            "invis.io",
#            "linear.app",
#            "miro.com",
#            "notion.so",
#            "trello.com",
#            "zeplin.io"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "cloud",
#      "label": "کلاود و هاستینگ",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "appspot.com",
#            "aws.amazon.com",
#            "bluemix.net",
#            "c9.io",
#            "cloudflare.com",
#            "cloudfront.net",
#            "cocalc.com",
#            "codesandbox.io",
#            "csb.app",
#            "digitalocean.com",
#            "download.virtualbox.org",
#            "es.io",
#            "firebase.com",
#            "fly.io",
#            "heroku.com",
#            "hetzner.com",
#            "ibm.com",
#            "java.com",
#            "linode.com",
#            "netlify.app",
#            "netlify.com",
#            "oracle.com",
#            "railway.app",
#            "render.com",
#            "replit.com",
#            "softlayer.com",
#            "sparkjava.com",
#            "supabase.com",
#            "vercel.app",
#            "vercel.com",
#            "virtualbox.org",
#            "vmware.com",
#            "zeit.co"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "education",
#      "label": "آموزش و مرجع",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "acm.org",
#            "arxiv.org",
#            "baeldung.com",
#            "cljdoc.org",
#            "codex.cs.yale.edu",
#            "coursehero.com",
#            "coursera-apps.org",
#            "coursera.com",
#            "coursera.org",
#            "datacamp.com",
#            "edx.org",
#            "fluttercrashcourse.com",
#            "flutterlearn.com",
#            "freecodecamp.org",
#            "goanimate.com",
#            "grabcad.com",
#            "hackerrank.com",
#            "ieee.org",
#            "jenkov.com",
#            "khanacademy.org",
#            "mathworks.com",
#            "medium.com",
#            "mit.edu",
#            "mybridge.co",
#            "overleaf.com",
#            "packtpub.com",
#            "piles.overleaf.com",
#            "proandroiddev.com",
#            "researchgate.net",
#            "sciencedirect.com",
#            "serverfault.com",
#            "spiceworks.com",
#            "springer.com",
#            "stackexchange.com",
#            "stackoverflow.com",
#            "superuser.com",
#            "teamtreehouse.com",
#            "udemy.com",
#            "udemycdn-a.com",
#            "udemycdn.com",
#            "wikia.com",
#            "wolframalpha.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "hardware",
#      "label": "سخت‌افزار و درایور",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "altera.com",
#            "amd.com",
#            "android.com",
#            "anydesk.com",
#            "arduino.cc",
#            "bitvise.com",
#            "cisco.com",
#            "clamav.net",
#            "dell.com",
#            "developer.samsung.com",
#            "digikey.com",
#            "download.01.org",
#            "element14.com",
#            "espressif.com",
#            "intel.com",
#            "lenovo.com",
#            "microchip.com",
#            "ni.com",
#            "nirsoft.net",
#            "qualcomm.com",
#            "raspberrypi.com",
#            "softonic.com",
#            "st.com",
#            "sun.com",
#            "teamviewer.com",
#            "ti.com",
#            "xilinx.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "finance",
#      "label": "پرداخت و مالی",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "coinbase.com",
#            "demandbase.com",
#            "en25.com",
#            "mailgun.com",
#            "paypal.com",
#            "paypalobjects.com",
#            "salesforce.com",
#            "sendgrid.com",
#            "stripe.com",
#            "upwork.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "webdev",
#      "label": "ابزار وب و فریم‌ورک",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "algolia.com",
#            "algolia.net",
#            "amp.dev",
#            "ant.design",
#            "apache.org",
#            "arcgis.com",
#            "atlassian.com",
#            "atlassian.net",
#            "b4x.com",
#            "beans.org",
#            "bit.dev",
#            "bitsrc.io",
#            "bootstrapcdn.com",
#            "bootswatch.com",
#            "bun.sh",
#            "caddy.com",
#            "caddyserver.com",
#            "cloudera.com",
#            "codecov.io",
#            "curd.io",
#            "dartlang.org",
#            "deno.land",
#            "developer.chrome.com",
#            "docs.datastax.com",
#            "elastic.co",
#            "enterprisedb.com",
#            "eslint.org",
#            "explainshell.com",
#            "expressjs.com",
#            "flutter.dev",
#            "flutter.io",
#            "forums.cpanel.net",
#            "gallery.io",
#            "getbootstrap.com",
#            "getcaddy.com",
#            "godbolt.org",
#            "grafana.com",
#            "graphql.org",
#            "hashicorp.com",
#            "hyper.is",
#            "i.stack.imgur.com",
#            "i18next.com",
#            "jaspersoft.com",
#            "javacardos.com",
#            "jenkins-ci.org",
#            "jenkins.org",
#            "jhipster.tech",
#            "jungle.net",
#            "laravel.com",
#            "material.io",
#            "mbed.com",
#            "metasploit.com",
#            "mongodb.com",
#            "mongodb.org",
#            "mysql.com",
#            "nativescript.org",
#            "nextjs.org",
#            "nginx.com",
#            "nodejs.org",
#            "php.net",
#            "polymer-project.org",
#            "postman.com",
#            "python.org",
#            "qt.io",
#            "rapid7.com",
#            "reactjs.org",
#            "realm.io",
#            "releases.hashicorp.com",
#            "ruby-doc.org",
#            "rust-lang.org",
#            "schema.org",
#            "seleniumhq.org",
#            "serialport.io",
#            "socket.io",
#            "sonarsource.com",
#            "splunk.com",
#            "spring.io",
#            "sstatic.net",
#            "swaggerhub.com",
#            "swift.org",
#            "symfony.com",
#            "telerik.com",
#            "terraform.io",
#            "traviscistatus.com",
#            "vagrantup.com",
#            "vuejs.org",
#            "vuetifyjs.com",
#            "web.dev"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "assets",
#      "label": "تصویر، فونت و قالب",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "3docean.net",
#            "codecanyon.net",
#            "cp.maxcdn.com",
#            "envato-static.com",
#            "envato.com",
#            "graphicriver.net",
#            "gravatar.com",
#            "justpaste.it",
#            "jwplayer.com",
#            "myfonts.net",
#            "photodune.net",
#            "themeforest.net",
#            "tinyjpg.com",
#            "tinypng.com",
#            "toggl.com",
#            "unsplash.com",
#            "videohive.net",
#            "vmcdn.com",
#            "wpastra.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "analytics",
#      "label": "تحلیل و تبلیغات",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "branch.io",
#            "bugsnag.com",
#            "count.ly",
#            "crashlytics.com",
#            "expo.io",
#            "fabric.io",
#            "fbsbx.com",
#            "flurry.com",
#            "fodev.org",
#            "lightstep.com",
#            "livefyre.com",
#            "newrelic.com",
#            "optimizely.com",
#            "parsely.com",
#            "sentry.io"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "bypass",
#      "label": "دور زده‌ها",
#      "groups": [
#        {
#          "key": "ea",
#          "label": "EA — سرورهای بازی",
#          "opt_in": true,
#          "note": "روشن کردنش بازی‌های EA را از سرور جدا می‌کند — این‌ها روی ۴۴۳ نیستند",
#          "domains": [
#            "gosredirector.ea.com",
#            "blaze.ea.com",
#            "gameservices.ea.com",
#            "tnt-ea.com"
#          ]
#        },
#        {
#          "key": "playstation",
#          "label": "PlayStation — STUN و API",
#          "opt_in": true,
#          "note": "روشن کردنش تشخیص NAT کنسول را خراب می‌کند",
#          "domains": [
#            "np.playstation.net",
#            "np.dl.playstation.net"
#          ]
#        },
#        {
#          "key": "epic",
#          "label": "Epic Games — بک‌اند بازی",
#          "opt_in": true,
#          "note": "روشن کردنش matchmaking فورتنایت را می‌شکند",
#          "domains": [
#            "account-public-service-prod.ol.epicgames.com",
#            "data-asset-directory-public-service-prod.ol.epicgames.com",
#            "datarouter.ol.epicgames.com",
#            "datastorage-public-service-live.ol.epicgames.com",
#            "ds.svc.live.fngw.ol.epicgames.com",
#            "events-public-service-live.ol.epicgames.com",
#            "fn-service-discovery-live-public.ogs.live.on.epicgames.com",
#            "fn-service-habanero-live-public.ogs.live.on.epicgames.com",
#            "fngw-svc-ds-livefn.ol.epicgames.com",
#            "fortnite-public-service-prod11.ol.epicgames.com",
#            "fortnitecontent-website-prod07.ol.epicgames.com",
#            "gc.svc.live.fngw.ol.epicgames.com",
#            "launcher-public-service-prod06.ol.epicgames.com",
#            "links-public-service-live.ol.epicgames.com",
#            "mcp-gc.live.fngw.ol.epicgames.com",
#            "prm-dialogue-public-api-prod.edea.live.use1a.on.epicgames.com"
#          ]
#        },
#        {
#          "key": "azure",
#          "label": "Azure — core.windows.net",
#          "opt_in": true,
#          "note": "روشن کردنش این اتصال‌ها را قطع می‌کند — SNI در مسیر مخدوش می‌شود",
#          "domains": [
#            "core.windows.net"
#          ]
#        }
#      ]
#    }
#  ]
#}
#__END_SERVICES__
