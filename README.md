<h2 align="center">تقدیم به حدیث❤️ که منو تو اولین پروژم یاری و تحمل کرد</h2>

# doctor dns

*[فارسی](README.fa.md)*

A smart DNS service for Iran, in two halves: a relay inside the country and an
exit node outside it. Sanctioned domains resolve to the relay, which carries
those connections abroad; everything else resolves normally and goes direct.

It is a whole service, not just a proxy — per-customer access control, traffic
accounting, quotas, speed limits, a customer panel and an operator panel, all
in one install script with no dependencies beyond what Debian ships.

**Alpha.** Running in production on three relay/exit pairs, but the interfaces
are still moving and there is no upgrade path between versions yet.

Which is why bug reports are worth more than anything else right now. If
something breaks, or a service you expected to work does not,
[open an issue](https://github.com/mehdi047/doctor-dns/issues) — say which
side it was, what you ran, and what happened. A report of one console failing
one download is a genuinely useful thing; most of what is in here was learnt
exactly that way.

---

## What it does

```
   customer            relay (Iran)              exit (abroad)          service
  ┌────────┐          ┌────────────┐            ┌───────────┐        ┌─────────┐
  │ PS5    │   DNS    │ dnsmasq    │            │           │        │ Sony    │
  │ phone  │ ───────► │  answers   │            │  nginx    │        │ Spotify │
  │ PC     │          │  with self │            │  reads    │        │ …       │
  │        │   TLS    │ nginx      │ ─────────► │  the SNI  │ ─────► │         │
  └────────┘ ───────► │  SNI proxy │            │           │        └─────────┘
                      │ nftables   │            └───────────┘
                      │  gate +    │
                      │  counters  │
                      └────────────┘
```

The relay never terminates TLS. nginx reads the SNI from the handshake and
opens a plain TCP tunnel to the exit, which does the same and connects to the
real host. Nothing decrypts anything, and no certificate is presented to the
client.

Port 80 is forwarded rather than redirected, because Sony and Microsoft serve
game packages over plain HTTP from Akamai edges that answer 443 with a
certificate naming no console host at all.

## What is in it

| | |
|---|---|
| **Routing** | dnsmasq hijacks a list of ~480 sanctioned domains; AAAA answers are filtered so clients cannot route around the proxy |
| **Games** | PlayStation, Xbox and Steam storefronts and downloads; EA, Epic; STUN/TURN on the relay so console NAT detection still works |
| **Access control** | an nftables allowlist keyed on the customer's address, with per-address byte counters in the kernel |
| **Quotas** | monthly or one-off, with warnings at 80% and 95% and automatic cutoff |
| **Speed limits** | a per-customer download cap, shaped with htb + fq_codel rather than by dropping packets |
| **Service templates** | which brands a customer's plan routes, down to individual domains; a few groups ship visible but unticked, because routing them breaks the thing they belong to |
| **Customer panel** | sign up, register an address, see usage, send a payment receipt |
| **Operator panel** | customers, templates, domains, host monitoring, backup and restore |
| **TLS** | certificates obtained and renewed automatically, asking for nothing but a domain name |

## Install

One script, run once on each machine. It asks which side it is on and the
address of the other.

```sh
curl -fsSLO https://raw.githubusercontent.com/mehdi047/doctor-dns/main/doctor-dns.sh && sudo bash doctor-dns.sh
```

It downloads rather than pipes on purpose. Every config this installs is
stored inside the script itself, below `exit 0`, so it has to be able to read
its own file — and it asks questions, which a pipe would answer with
end-of-file. Downloading also leaves you a copy to read, to re-run, and to
uninstall from. It refuses to run if that copy is not whole.

Run the **exit** first: it prints a pairing token that the relay asks for.

Safe to re-run — configs are backed up, and a step that would change nothing
does nothing. `sudo bash doctor-dns.sh --uninstall` puts the machine back,
undoing only what this script did.

### Upgrading

Download the new file and run it. Before it touches anything it compares its
own version against what the machine has, says which way it is going, and
waits for an answer:

```
Version

    installed on this machine:  0.1.0
    this file:                  0.2.0

    this will upgrade this machine from 0.1.0 to 0.2.0.
    your customers, settings, certificates and allowlist are kept.

  go ahead? [y]:
```

The case worth having it for is the other one. Run an old file over a newer
install — a download still sitting in a home directory, months later — and it
says so, and the default answer becomes no.

Your customers, their usage, the sync secret, the panel password and any
certificate all live outside the files the script writes, so an upgrade keeps
them. A copy of the database is taken into `/var/backups/smart-dns/` first
anyway, with `VACUUM INTO` rather than `cp`, because the panel keeps a
write-ahead log beside the database and copying the file alone can miss its
newest rows. `--version` prints what a file is without installing anything,
and `ASSUME_YES=1` takes the default — yes for an upgrade, no for a
downgrade — for anyone scripting it.

### Requirements

Two machines with Debian or Ubuntu and a public address each:

- **relay** — inside Iran, the address customers point their DNS at
- **exit** — outside, reachable from the relay

No pip, no npm, no containers. Python's standard library, nginx, dnsmasq,
nftables and coturn, all from the distribution.

### Ports

Everything below is taken by the service. Open them in the firewall, and do
not give any of them to the admin panel — the installer refuses the ones it
can see, but a firewall rule you wrote yourself it cannot.

| | relay (inside Iran) | exit (abroad) |
|---|---|---|
| **53** udp + tcp | dnsmasq, the address customers point at | — |
| **80** tcp | forwarded abroad; also how certificates are proved | the same |
| **443** tcp | the SNI proxy | the same |
| **3478** udp | STUN, so a console can work out its own NAT | — |
| **8080** tcp | the customer panel, where there is no certificate | — |
| **8443** tcp | the customer panel, where there is one | the sync API the relays connect to |
| **22** tcp | ssh — never gated, so a wrong allowlist cannot lock you out | the same |

The admin panel is the one port you choose. It defaults to **9443** and can be
anything free; the installer stops you at 22, 53, 80, 443 and 8443, and
`smartdns-access port` applies the same rule later, plus a check that nothing
else is already listening.

Inbound, the relay is the machine customers reach, so its DNS, proxy, STUN and
panel ports have to be open to the internet. The exit only ever hears from the
relay and from you, so 80, 443, 8443 and the panel port are enough there.

### Access control

A fresh relay answers everyone. That is not a default anybody chose - it is
that a relay is installed before a single address is registered, and closing
it against an empty allowlist cuts off every user at once, the operator
included.

So the relay closes itself at the first sync that brings a registered
address, and only registered addresses get DNS, HTTP and HTTPS from then on.
SSH is never gated, so a wrong allowlist cannot cost anyone access to the
machine.

```sh
smartdns-acl enforce status   # which it is right now
smartdns-acl enforce off      # stay open, and cancel the automatic close
```

`ENFORCE=no` on the installer's command line opts out from the start.

## After installing

```sh
smartdns status              # what this machine is doing
smartdns-acl list            # who is allowed, and what they have used
smartdns-shape list          # who is speed limited
smartdns-cert example.com    # a certificate for a panel
smartdns-access              # where the operator's panel answers
smartdns-access password     # change it; also port and path
```

Each side prints what it set up at the end of its install: the relay names the
DNS address and the customers' panel, the exit names the operator's panel and
its password, shown once.

The operator's panel is the whole administrative interface - customers, their
quotas and speeds, service templates, the domain list, host monitoring,
payment receipts, and backup and restore. `smartdns-access` exists for the one
case the panel cannot help with: getting back in after its port or path was
changed to something the firewall does not allow.

## How it is built

`doctor-dns.sh` is generated, not hand-edited. Everything lives in
`templates/`, `common/` and `domains/`; `tools/installer-logic.sh` is the
script's logic, and `tools/build-installer.py` staples them together:

```sh
python3 tools/build-installer.py   # rewrites doctor-dns.sh
bash -n doctor-dns.sh              # it stays valid bash
python3 tools/test-websignup.py    # …and so on for the rest
```

Payloads sit below `exit 0` with every line `#`-prefixed, which is what keeps
the whole file valid bash — so `bash -n` genuinely checks it, and a reviewer
can read every config they are about to run as root.

## Shape of a deployment

One database serves every relay. That is what makes a customer's allowance
mean one thing across the service rather than one thing per machine.

```
  exit node                          relay(s)
  ┌──────────────────────┐          ┌──────────────────────┐
  │ smartdns-panel       │ ◄─────── │ smartdns-sync        │
  │  sqlite + sync API   │   30s    │  usage up,           │
  │                      │ ───────► │  allowlist down      │
  │ smartdns-admin       │          │                      │
  │  operator's panel    │          │ customer's panel     │
  └──────────────────────┘          └──────────────────────┘
```

The relay always dials out. It is the machine in the harder network position,
and this way it needs no new inbound port.

The customer's panel lives on the relay because the point of it is to learn
the customer's address, and only the relay sees the address they actually
reach the service from.

## Known limits

- **Upload is not shaped.** Only the download direction is capped. Policing
  ingress needs an ifb device and drops rather than queues, for a service
  whose traffic is overwhelmingly inbound.
- **A relay without a certificate has no customer panel.** Passwords are not
  offered over plain HTTP, so such a relay serves a page saying so.
- **Selling is not built, and there is no trial.** Signing up gets an account,
  a password, and somewhere to send a receipt — no traffic. The account waits
  until an operator opens its row and gives it a plan, which is the moment it
  becomes able to connect at all.
- **Xbox downloads stall** regardless of whether they are routed. Measured,
  not solved.
- **Traffic costs double.** One customer gigabyte is about two on the relay
  and two on the exit — measured, and worth knowing before pricing anything.

## Contributors

- [Armin Toranj](https://github.com/arminandtoo) — `@arminandtoo`

## Licence

MIT. See [LICENSE](LICENSE).

The domain list is assembled from public sources and from testing; it is not
exhaustive and will drift as services change.
