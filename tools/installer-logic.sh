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

case "${1:-}" in
    --uninstall|-u|uninstall) uninstall ;;
    --help|-h)
        printf 'usage: %s [--uninstall]\n' "$0"
        printf '  no arguments   install or update this machine\n'
        printf '  --uninstall    put it back as it was\n'
        exit 0 ;;
    "") ;;
    *) die "unknown argument: $1  (try --help)" ;;
esac

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
        payload CERT > /usr/local/bin/smartdns-cert
        chmod +x /usr/local/bin/smartdns-cert
        note_file /usr/local/bin/smartdns-cert
        install_payload CERT_SERVICE /etc/systemd/system/smartdns-cert.service || true
        install_payload CERT_TIMER   /etc/systemd/system/smartdns-cert.timer   || true
        systemctl daemon-reload
        /usr/local/bin/smartdns-cert "$PANEL_DOMAIN" || die "could not get a certificate"
        enable_service smartdns-cert.timer
        systemctl start smartdns-cert.timer 2>/dev/null || true
    fi
    [ -f "$CERT_PATH" ] || die "still no certificate at $CERT_PATH"
    remember panel-domain "$PANEL_DOMAIN"
fi

# ----------------------------------------------------------------- panel
SYNC_TOKEN_OUT=""
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
CLAIM_PORT=8080
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
                53|80|443|8443|22) die "port $ADMIN_PORT is already the service's own" ;;
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
    # Where the customer's panel ended up, for the summary at the end. The
    # ports match smartdns-sync's own constants: 8443 when there is a
    # certificate to serve it with, 8080 otherwise. Both sit outside the gated
    # ports on purpose, so somebody whose address changed can still reach the
    # page that fixes it.
    if [ -n "${PANEL_DOMAIN:-}" ]; then
        USER_PANEL_OUT="https://$PANEL_DOMAIN:8443/"
    else
        USER_PANEL_OUT="http://$SELF_IP:8080/"
    fi
    # Ask for the relay to be closed as soon as there is somebody to allow.
    # It cannot be closed here: a relay is paired before anyone has registered,
    # and enforcing against an empty allowlist cuts off everyone including
    # whoever is running this. The sync agent acts on this note at the first
    # sync that brings an address, and `smartdns-acl enforce off` cancels it.
    if [ "${ENFORCE:-yes}" = no ]; then
        rm -f /etc/smart-dns/auto-enforce
        info "ENFORCE=no - this relay will stay open until you close it by hand"
    elif [ -f /etc/nftables.d/30-smartdns-enforce.conf ]; then
        info "access control is already on"
    else
        : > /etc/smart-dns/auto-enforce
        AUTO_ENFORCE_OUT=1
    fi
    if systemctl is-active --quiet smartdns-sync.service; then
        info "syncing with the panel at $PANEL_HOST every 30s"
        info "customer panel on $USER_PANEL_OUT"
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
    printf '%s%s is installed and working.%s\n' "$G" "$ROLE" "$N"
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

if [ -n "${AUTO_ENFORCE_OUT:-}" ]; then
    printf '    %sAccess control%s - this relay is open right now, because nobody has
    registered an address yet and closing it on an empty list would cut off
    everyone. It closes itself the moment the first address is registered,
    and only registered addresses get DNS, HTTP and HTTPS after that. SSH is
    never affected.

        smartdns-acl enforce status     see which it is
        smartdns-acl enforce off        stay open, and cancel this

' "$B" "$N"
fi

if [ -n "${USER_PANEL_OUT:-}" ]; then
    printf '    %sCustomer panel%s - where people sign up, register the address the
    service works on, see what is left of their allowance, and send a payment
    receipt. It also shows them the DNS address to enter.

        %s

' "$B" "$N" "$USER_PANEL_OUT"
    if [ -z "${PANEL_DOMAIN:-}" ]; then
        printf '    %sSign-up and sign-in are switched off there%s, because without a
    certificate that page is plain http and a password would be readable in
    transit. Give this machine a domain and run:

        smartdns-cert panel.example.com

    then put PANEL_DOMAIN in /etc/smart-dns/sync.env and restart
    smartdns-sync.

' "$Y" "$N"
    fi
fi

if [ -n "${ADMIN_URL_OUT:-}" ]; then
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
