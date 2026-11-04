# CLAUDE.md

An AirPrint bridge for Home Assistant, in two halves:

- **`airprint/`** — the add-on. CUPS + Avahi + the printer's driver. Published as a container image.
- **`custom_components/airprint/`** — the integration. The setup screens and the sensors.

The integration **owns the printer list** and writes it into the add-on's options through the Supervisor API. Anything hand-edited in the add-on's YAML is overwritten on the next sync — printer settings belong in the integration's form.

## Why two pieces

The split was arrived at the hard way; do not relitigate it. An add-on's options only render a friendly form for a **flat** schema, so a list of printers collapses to a raw YAML editor, and add-ons cannot offer Home Assistant selectors. Entities pushed from an add-on via the REST states API are not registry entities, so they get no Areas and cannot be renamed. Only an **integration** gives proper registry entities (a device per printer, renameable, assignable to Areas) with no MQTT broker. So the integration owns the UI and the entities; the add-on is just the print engine plus a status feed. The integration auto-discovers the add-on from an mDNS advert (`_airprint-status._tcp`) and drives it through the Supervisor API, the same pattern Z-Wave JS uses.

## How it works

- **The add-on** runs CUPS 2.4 (pinned to Debian bookworm; CUPS 3.x drops PPD drivers) + Avahi. A shared PPD queue makes CUPS 2.4 advertise AirPrint automatically, so no `.service` files or `cupsFilter2` hacks (those are pre-2.4 and harmful). `monitor.sh` counts print jobs every 15 s (one `lpstat -o`) and runs the full scan (discovery, SNMP, driver matching) every 60 s. It writes `/srv/status.json`, served on `:8099`, which the integration polls every 15 s, so a job for a switched-off printer reaches Home Assistant within ~30 s: fast enough for a wake-on-print automation.
- **Discovery is passive mDNS.** `discover.sh` reads the printer's `_pdl-datastream._tcp` advert (model and device-id come from its TXT record: `usb_MFG` / `usb_MDL` / `ty` / `product`) and matches a driver from the local PPD database (`lpinfo -m`). It must **never** run CUPS device discovery (`lpinfo -v`) on a timer, for the reason below.
- **Status is SNMP, never the print port.** Liveness is an SNMP `sysUpTime` read (UDP 161, the management plane). Health is the `hrPrinterDetectedErrorState` bitmask (0x40 out of paper, 0x04 jam, 0x08 door open, 0x20 toner low, etc.). Toner and page count are SNMP too. In `status.json`, `problem` is only TCP reachability and `reasons` is only the SNMP decode; the integration ORs them (plus no-driver) for the Health entity, so `"problem": false` alongside `"reasons": ["Out of paper"]` is correct.
- **NEVER open the printer's raw print port (9100/515) on a timer.** Many printers (Canon MFPs especially) treat any TCP connection to 9100 as an incoming job and audibly wake. This caused a once-a-minute "phantom beep" that took two passes to kill: first `monitor.sh`'s own `port_open` liveness probe, then the CUPS **snmp backend** that `lpinfo -v` invokes during discovery (after finding the printer over SNMP it opens 9100 to read the IEEE-1284 device-id via PJL). Use SNMP or IPP Get-Printer-Attributes for liveness and passive mDNS for discovery. Nothing should touch 9100 except a real print job. A 9100 SYN with `UID=7` (lp) fingerprints a CUPS backend, not `monitor.sh` (root).
- **Identity is the Bonjour name.** The queue's device URI is `dnssd://<service>._pdl-datastream._tcp.local/`; CUPS' dnssd backend resolves it to an address at job time, so no IP is stored and the printer's IP can change freely.

## Testing on the Home Assistant box

There is no plain SSH into HA OS. Root + `docker` is reached through the Proxmox host and the QEMU guest agent:

```bash
ssh pve
qm guest exec 100 -- /bin/sh -c '<command>'
# for anything non-trivial, base64 it (emoji and nested quotes do not survive the shell):
qm guest exec 100 -- /bin/sh -c 'echo <BASE64> | base64 -d | sh'
```

- Supervisor CLI: `docker exec hassio_cli ha apps ...` / `ha store reload` / `ha core restart` (the CLI still accepts the old `addons` verb but prints a deprecation; prefer `apps`).
- Published-store slug: `0f9301c3_airprint`, container `app_0f9301c3_airprint`. Local dev build: `local_airprint`, container `app_local_airprint`.
- Inspect the running add-on with `docker exec app_0f9301c3_airprint cat /srv/status.json`, and `docker inspect` for RestartCount/StartedAt. `ha apps logs` is a rolling buffer that keeps pre-restart lines, so do not mistake old lines for live looping.
- A printer that fell to a link-local `169.254.x` address (lost its DHCP lease) makes cupsd restart-loop; fix the printer, not the add-on.
- No tcpdump/conntrack on HA OS. To watch for stray 9100 traffic, arm an `iptables` OUTPUT LOG rule on SYNs to the printer and read hits from `dmesg`.

## Developing

Iterate with `scripts/dev.sh`. It pushes the working tree onto the Home Assistant box, strips the `image:` key so the Supervisor **builds the add-on locally**, and rebuilds it. **No version bump, nothing published, no tags.**

```bash
scripts/dev.sh              # add-on + integration, then restart Home Assistant
scripts/dev.sh addon        # add-on only
scripts/dev.sh integration  # integration only
```

Two things that will waste your time if you forget them:

- **The add-on only picks up changes on a rebuild.** `ha apps rebuild` does it without a version bump. A plain restart re-runs the *existing* image.
- **The integration only picks up changes when Home Assistant Core restarts.** Copying files in is not enough.

Verify against the real thing rather than asserting. The add-on's log and `/srv/status.json` (served on `:8099`) say what it actually did.

## Releasing

This is the **Gyang91 fork**; releases are automatic (release-please, same setup as the user's other forks).

The version lives in **two files that must always match**, because the Supervisor pulls `<image>:<version from config.yaml>`:

- `airprint/config.yaml` → `version:`
- `custom_components/airprint/manifest.json` → `"version"`

Never edit them by hand. release-please bumps both (`extra-files` in `release-please-config.json`) from the conventional commits on `main`:

1. Push or merge `feat:` / `fix:` / `perf:` commits to `main` (`auto-merge.yml` merges the owner's green pull requests and Dependabot's).
2. `release.yml` opens or updates the release pull request, checks it, merges it and tags `vX.Y.Z` in the same run.
3. The same run builds `amd64` and `aarch64`, and publishes one multi-arch image to `ghcr.io/gyang91/ha-airprint/airprint` (lowercase: GHCR rejects capitals).

`chore:`, `ci:`, `docs:`, `test:` do not release. To force a version, add `Release-As: X.Y.Z` to a commit body.

The GHCR package must be **public**, or the Supervisor cannot pull it. It inherits the public repository's visibility (checked on the first publish, 2026-11-04). Verify with an anonymous pull: `curl "https://ghcr.io/token?scope=repository:gyang91/ha-airprint/airprint:pull"`, then request `/v2/gyang91/ha-airprint/airprint/manifests/<version>` with that token; it must return 200.

## Keep the README current

The README is the front door. **Any change to features, options, fields or behaviour lands in the README in the same commit.** Someone who finds this repo should read it once and have their printer printing.

Write for **a Home Assistant user who wants their printer on AirPrint** — not for the author, and not as a story about the problem. Keep it light:

- Lead with whether they need this at all, then install, then adding the printer. Say "that's it" where they are actually done.
- Document what a user sees and touches: the fields, the sensors, what to do when a driver is missing.
- Leave out internals unless they change what a user does.
- Examples are copied from real output — re-check them when behaviour changes.

## Conventions

- **Home Assistant's conventions win.** Sentence-case entity names, its device classes and their fixed state text, its selectors. If a request conflicts with one, say so before deviating.
- **The data model mirrors the UI.** One key per field the user sees.
- **Proprietary drivers are never bundled.** They are downloaded at runtime from a URL on the printer, or dropped into `/share/airprint/drivers`. A published image ships only the free driver set — that is what makes it publishable at all.

## Traps worth knowing

Each of these cost real debugging time at least once.

- **iOS renders the Bonjour service name as the printer "icon", and ignores the IPP `printer-icons` image entirely.** That is why the add-on prefixes an emoji to the advertised name (the `icon` option). macOS does fetch `printer-icons`.
- **Canon UFR II is proprietary** and in no free driver set; Aaron's printer pulls its driver from his own CDN at runtime. The Canon PPD is `CNRCUPSMF4800ZK.ppd` (`CNR`, not the `CNCUPS...` most sources cite).
- **Printer icons are served from CUPS' `CacheDir`** (`/var/cache/cups/images/<queue>.png`), not doc-root. The directory must exist or the advertised icon URL always 404s.
- **Installing any cups package starts Debian's own cupsd** on port 631; ours then cannot bind and `lpadmin` talks to the wrong daemon (returns `Unauthorized`). `pkill -x cupsd` after driver install, before starting ours. This looks exactly like a permissions bug and is not one.
- **`ping` never works inside the container** (no raw-socket capability). Probe with SNMP or TCP.
- **The add-on must keep running with zero printers.** It used to `exit 1`, which killed the status API and mDNS advert, so a fresh install was undiscoverable and you could never add the first printer.
- **Home Assistant's own IPP integration will discover our CUPS queue** and offer a redundant card. Unavoidable, because we must advertise `_ipp._tcp` for AirPrint. Tell the user to Ignore it.
- **Renaming a printer leaves ghost Bonjour records** cached in resolvers for up to an hour. Verify what is really published by asking cupsd (`ipptool ... | grep printer-dns-sd-name`), not by browsing mDNS.
- **The queue id is slugified from the printer name**, so two printers with the same name collided until ids were suffixed (`_2`). That suffixing is what makes same-name-different-icon work.
- **A host reboot can start the add-on before mDNS is flowing** (it comes up seconds after the Supervisor). The one-shot boot discovery then sees no printer, matches no driver, and creates no queue - which surfaces as a bogus "needs a driver" repair. That is why `monitor.sh` retries driver matching and queue creation every cycle via `queue.sh`; keep queue setup reachable from the monitor loop.
- **The Supervisor renamed add-on containers from `addon_<slug>` to `app_<slug>`** (with the addons-to-apps rename). Anything shelling into the container must use the `app_` prefix.
- **`awk -v name=...` rewrites avahi's escapes** (`\032` is a space in `avahi-browse -p` output, awk reads it as an octal escape). Every printer with a space in its Bonjour name failed to resolve, so it read Offline and never got SNMP status. `monitor.sh` no longer browses by name at all: it takes the address `discover.sh` already resolved. If a name must go through awk again, pass it via `ENVIRON`.
- **dbus, Avahi and cupsd are children of `run.sh`, and it exits when one stops** (`wait -n`); the Supervisor watchdog restarts the add-on. Before, only cupsd was watched: a dead Avahi left the add-on "running" while phones lost the printer. Never start them with `--daemonize`/`--fork`, or they escape that watch. Avahi runs with `--syslog`, or it floods the add-on log with every interface change. The helpers (monitor, status feed, its advert) are not needed to print: `keep_running` restarts them in place, so a bug in the monitor can never crash-loop printing.
- **Never pass fields between the scripts tab-separated.** `read` with `IFS=$'\t'` treats tab as whitespace and collapses an empty field, so an empty location shifted the driver into it: every add-on start re-created the queue with the location "everywhere". `match.sh` defines `SEP` (ASCII unit separator) and `row`; use them for `/tmp/airprint-queues` and `match` output.
- **iOS ignores a profile (AirPrint payload) printer without `ForceTLS`** when it is off the home network: "No AirPrint Printers Found", although Safari on the same phone loads `http://<ha>:631/printers/`. With `ForceTLS` true it works; CUPS serves TLS on 631 with its self-signed certificate. Verified 2026-11-04 over WireGuard.
- **A sleeping printer can miss an mDNS browse** (the HP 135w does after a few idle minutes), which read as Offline while it was on. `monitor.sh` keeps the last address per device (`KNOWN_HOSTS`): advertised or not, a printer that answers SNMP is Online. Only an advertised printer that does not answer is a Problem.
- **SNMP status is one request** (`snmp_status`, `-Oqn`, values matched by OID). SNMPv1 drops an object the printer lacks and retries the rest, so match by OID, never by line position.
- **`lpadmin -m everywhere` crashes cupsd 2.4.2 (bookworm)** with `free(): invalid pointer`. Driverless PPDs are built by cups-filters in its own process instead (`/usr/lib/cups/driver/driverless cat driverless:ipp://...`) and installed with `lpadmin -P`.
- **cups-filters lists a reachable AirPrint printer as a `driverless:ipp://...` model**, so `lpinfo --device-id` "matches" it. That PPD only exists while the printer is on, and its raster output belongs on IPP, not the raw port: `discover.sh` turns such a match into the driverless path (IPP URI, PPD cached in `/config/driverless`).
- **Our own CUPS advertises every shared queue over `_ipp._tcp`**, so IPP discovery finds "<queue> @ home-assistant" on this host and would offer it as a new driverless printer. `discover.sh` skips adverts from the host's own addresses (`hostname -I`; the add-on runs on the host network).
- **CUPS gives a job up after `JobRetryLimit` retries** (default 5 x 30 s). A printer switched on by an automation needs longer to boot, so `cupsd.conf` sets 40 (20 min).
- **A dnssd URI needs the service name URL-encoded** (`HP%20Laser%20(x)`), not avahi's `\032` escapes. The stored `device` identity keeps the avahi form for compatibility; only the print `uri` is encoded.

## Security scanning

`.github/workflows/security.yml` builds the image and scans it with Trivy (official `aquasec/trivy` image; the trivy-action install script failed to download) on every push, pull request and weekly. It fails only on **fixable** HIGH/CRITICAL findings and uploads the full report to Security > Code scanning. The Dockerfile runs `apt-get upgrade`, so a rebuild (any release) takes Debian's current security updates; when the weekly scan fails, cut a release.

Most open alerts have **no fix in Debian bookworm** (nor trixie). Checked 2026-11-04 for the network-facing CUPS ones:

- **CVE-2026-34980** (fixed in CUPS 2.4.17, Debian sid/forky only): needs a shared **PostScript** queue. Driverless queues here are PWG raster.
- **CVE-2026-55453** (fixed in 2.4.20, sid only): needs a **Foomatic** queue and a malicious printer on the network feeding status messages.
- **CVE-2024-47850**: cups-browsed, which is not installed (the alert comes from `libfontembed1`, built from the same source).

cupsd only accepts the local network (`Allow @LOCAL`). Moving to Debian testing would fix these but trades a stable base for a moving one; revisit when a stable release ships CUPS >= 2.4.20.
