#!/bin/sh
#
# doctor dns - one-line install.
#
#   curl -fsSL https://raw.githubusercontent.com/mehdi047/doctor-dns/main/get.sh | sudo sh
#
# All this does is fetch doctor-dns.sh, check it arrived whole, and hand
# over to it. Everything that matters happens in that file, which is the one
# worth reading before running any of this:
#
#   https://github.com/mehdi047/doctor-dns/blob/main/doctor-dns.sh
#
# Arguments go through to it:
#
#   ... | sudo sh -s -- --uninstall
#
# REF installs from a tag or branch instead of main; DEST puts the script
# somewhere else.
set -eu

REPO="${REPO:-mehdi047/doctor-dns}"
REF="${REF:-main}"
DEST="${DEST:-/usr/local/src/doctor-dns}"
URL="https://raw.githubusercontent.com/$REPO/$REF/doctor-dns.sh"

if [ -t 1 ]; then
    B=$(printf '\033[1m'); G=$(printf '\033[32m'); RD=$(printf '\033[31m')
    N=$(printf '\033[0m')
else
    B=''; G=''; RD=''; N=''
fi
say() { printf '%s==>%s %s%s%s\n' "$G" "$N" "$B" "$*" "$N"; }
die() { printf '\n%sERROR:%s %s\n\n' "$RD" "$N" "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root:  curl -fsSL .../get.sh | sudo sh"

if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -qO "$2" "$1"; }
else
    die "neither curl nor wget is installed:  apt-get install -y curl"
fi

say "fetching $REF"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT INT TERM
fetch "$URL" "$tmp" || die "could not download $URL"

# A truncated download is the failure worth catching here. The installer
# carries every config it writes in its own tail, so half of it is still a
# runnable script - one that would set up a machine with pieces missing.
# Four cheap checks, and none can be true of a partial file.
size=$(wc -c < "$tmp")
[ "$size" -gt 200000 ] || die "downloaded only $size bytes - that is not the whole installer"
head -1 "$tmp" | grep -q '^#!/usr/bin/env bash' || die "that download is not the installer"
tail -2 "$tmp" | grep -q '^#__END_' || die "the download stops mid-payload - try again"
bash -n "$tmp" || die "the download does not parse as bash - try again"

mkdir -p "$DEST"
install -m 755 "$tmp" "$DEST/doctor-dns.sh"

say "installer saved to $DEST/doctor-dns.sh"
if command -v sha256sum >/dev/null 2>&1; then
    # Printed, not checked against anything. It tells you the bytes here are
    # the bytes you can hash yourself on github.com/$REPO - it is not a
    # signature and does not vouch for what those bytes do.
    printf '    sha256  %s\n' "$(sha256sum < "$DEST/doctor-dns.sh" | cut -d' ' -f1)"
fi

# The installer asks which side of the service this machine is, the address
# of the other one, and a password. Piped into sh, this script's stdin is the
# pipe, so every one of those prompts would read end-of-file and the install
# would run on answers nobody gave. Hand it the terminal instead.
if [ -t 0 ]; then
    exec bash "$DEST/doctor-dns.sh" "$@"
elif [ -e /dev/tty ] && (: < /dev/tty) 2>/dev/null; then
    exec bash "$DEST/doctor-dns.sh" "$@" < /dev/tty
fi

printf '\n    This install asks questions and there is no terminal to ask on.\n'
printf '    The installer is downloaded and checked. Run it yourself:\n\n'
printf '        sudo bash %s/doctor-dns.sh%s\n\n' "$DEST" "${*:+ $*}"
exit 1
