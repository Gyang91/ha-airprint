# CLAUDE.md

An AirPrint bridge for Home Assistant, in two halves:

- **`airprint/`** — the add-on. CUPS + Avahi + the printer's driver. Published as a container image.
- **`custom_components/airprint/`** — the integration. The setup screens and the sensors.

The integration **owns the printer list** and writes it into the add-on's options through the Supervisor API. Anything hand-edited in the add-on's YAML is overwritten on the next sync — printer settings belong in the integration's form.

## Why two pieces

The split was arrived at the hard way; do not relitigate it. An add-on's options only render a friendly form for a **flat** schema, so a list of printers collapses to a raw YAML editor, and add-ons cannot offer Home Assistant selectors. Entities pushed from an add-on via the REST states API are not registry entities, so they get no Areas and cannot be renamed. Only an **integration** gives proper registry entities (a device per printer, renameable, assignable to Areas) with no MQTT broker. So the integration owns the UI and the entities; the add-on is just the print engine plus a status feed. The integration auto-discovers the add-on from an mDNS advert (`_airprint-status._tcp`) and drives it through the Supervisor API, the same pattern Z-Wave JS uses.

## How it works

- **The add-on** runs CUPS 2.4 (pinned to Debian bookworm; CUPS 3.x drops PPD drivers) + Avahi. A shared PPD queue makes CUPS 2.4 advertise AirPrint automatically, so no `.service` files or `cupsFilter2` hacks (those are pre-2.4 and harmful). `monitor.sh` counts print jobs every 15 s (one `lpstat -o`) and runs the full scan (discovery, SNMP, driver matching) every 60 s. It writes `/srv/status.json`, served on `:8099`, which the integration polls every 15 s, so a job for a switched-off printer reaches Home Assistant within ~30 s: fast enough for a wake-on-print automation.
- **Queues are created in one place: `monitor.sh`'s scan.** `run.sh` only writes the printer list (`/tmp/airprint-queues`, no driver yet); the monitor's first scan, straight after start, matches a driver and runs `queue.sh`, and keeps retrying a printer that has none. Do not add a second path in `run.sh`.
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

Every merge deletes its branch: `auto-merge.yml` (`--delete-branch`) and `release.yml` (`--delete-branch`; with `--repo` gh only deletes the remote branch, never touches the job's checkout) do it themselves, because GitHub's auto-delete setting ignores merges made with `GITHUB_TOKEN`; `delete_branch_on_merge` in `.github/settings.yml` covers merges by hand. `prune-branches.yml` (daily, and when a pull request closes) deletes the rest: a branch whose pull request is merged or closed and that has not moved since, or one with nothing that is not already on `main`. It never touches `main`, protected branches or a branch with an open pull request; run it by hand with "dry run" to preview.

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
- **A driver link must be https and end in the file's name** (`driver_error` in `const.py`; the form refuses anything else). A link saved before that check is left alone, so existing setups keep working; `drivers.sh` still downloads a plain http one, with a warning, and refuses an https link that redirects to http.

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
- **A host reboot can start the add-on before mDNS is flowing** (it comes up seconds after the Supervisor). Discovery then sees no printer and matches no driver - which surfaced as a bogus "needs a driver" repair. That is why `monitor.sh` retries driver matching and queue creation every scan, and is now the only place queues are created.
- **The CUPS snmp backend is removed from the image** (and kept out with a debconf answer, `cupsys/backend`, because reconfiguring `cups` relinks backends). Its discovery opens 9100 on every printer it finds. `CUPS-Get-Devices` (device discovery, the web interface's "Add Printer") is `@SYSTEM` in `cupsd.conf` for the same reason: anyone allowed to print could trigger it. CI fails if the backend is back.
- **Driver matches are cached in `/tmp/airprint-matches`** (`discover.sh`): each `lpinfo -m` reads the whole PPD database (1-8 s), per printer, per scan. The database only changes when `drivers.sh` runs at start, and a new container starts with an empty `/tmp`. Only a real answer (a match or `client-error-not-found`) is cached, never a cupsd that did not answer.
- **The Supervisor runs a new container on every add-on start** (every printer edit restarts it), so `/tmp` is empty each start; a plain `docker restart` keeps it, which does not reproduce start-up bugs. State that must outlive a start goes in `/data` (`/data/airprint-notified`: notifications already sent, so a dismissed one stays dismissed).
- **"Needs a driver" is a repair in the integration only.** The add-on used to send a persistent notification too; it now only dismisses that old one once per start.
- **The Supervisor renamed add-on containers from `addon_<slug>` to `app_<slug>`** (with the addons-to-apps rename). Anything shelling into the container must use the `app_` prefix.
- **`awk -v name=...` rewrites avahi's escapes** (`\032` is a space in `avahi-browse -p` output, awk reads it as an octal escape). Every printer with a space in its Bonjour name failed to resolve, so it read Offline and never got SNMP status. `monitor.sh` no longer browses by name at all: it takes the address `discover.sh` already resolved. If a name must go through awk again, pass it via `ENVIRON`.
- **dbus, Avahi and cupsd are children of `run.sh`, and it exits when one stops** (`wait -n`); the Supervisor watchdog restarts the add-on - if the user turned **Watchdog** on (the README says to). No `watchdog:` URL is set in `config.yaml`: how the Supervisor resolves its port for a host-network add-on was not verified, and a wrong one would restart the add-on in a loop. Before, only cupsd was watched: a dead Avahi left the add-on "running" while phones lost the printer. Never start them with `--daemonize`/`--fork`, or they escape that watch. Avahi runs with `--syslog`, or it floods the add-on log with every interface change. The helpers (monitor, status feed, its advert) are not needed to print: `keep_running` restarts them in place, so a bug in the monitor can never crash-loop printing.
- **Never pass fields between the scripts tab-separated.** `read` with `IFS=$'\t'` treats tab as whitespace and collapses an empty field, so an empty location shifted the driver into it: every add-on start re-created the queue with the location "everywhere". `match.sh` defines `SEP` (ASCII unit separator) and `row`; use them for `/tmp/airprint-queues` and `match` output.
- **Printer-control IPP operations need `@SYSTEM`** (`cupsd.conf`, as in CUPS' default policy). They used to fall under `<Limit All>`, so anyone allowed to print could pause the printer, make it reject jobs or cancel every job without signing in; it matters more once a VPN subnet may print. The add-on's own `lpadmin` is root on the local socket, so it is unaffected. The TLS certificate lives in `/config/ssl` (`ServerKeychain`), so it survives updates.
- **iOS ignores a profile (AirPrint payload) printer without `ForceTLS`** when it is off the home network: "No AirPrint Printers Found", although Safari on the same phone loads `http://<ha>:631/printers/`. With `ForceTLS` true it works; CUPS serves TLS on 631 with its self-signed certificate. Verified 2026-11-04 over WireGuard.
- **A sleeping printer can miss an mDNS browse** (the HP 135w does after a few idle minutes), which read as Offline while it was on. `monitor.sh` keeps the last address per device (`KNOWN_HOSTS`): advertised or not, a printer that answers SNMP is Online. Only an advertised printer that does not answer is a Problem.
- **Silence from SNMP is only a Problem for a printer that has answered before** (`SNMP_SEEN`, since the add-on started). A printer with no SNMP agent used to read Problem / "Not accepting jobs" forever, because "advertised but not answering SNMP" was the stuck rule. It stays in memory, not `/data`: persisting it would make a printer whose SNMP was switched off a Problem forever.
- **SNMP status is one request** (`snmp_status`, `-Oqn`, values matched by OID). SNMPv1 drops an object the printer lacks and retries the rest, so match by OID, never by line position.
- **`lpadmin -m everywhere` crashes cupsd 2.4.2 (bookworm)** with `free(): invalid pointer`. Driverless PPDs are built by cups-filters in its own process instead (`/usr/lib/cups/driver/driverless cat driverless:ipp://...`) and installed with `lpadmin -P`.
- **cups-filters lists a reachable AirPrint printer as a `driverless:ipp://...` model**, so `lpinfo --device-id` "matches" it. That PPD only exists while the printer is on, and its raster output belongs on IPP, not the raw port: `discover.sh` turns such a match into the driverless path (IPP URI, PPD cached in `/config/driverless`).
- **Our own CUPS advertises every shared queue over `_ipp._tcp`**, so IPP discovery finds "<queue> @ home-assistant" on this host and would offer it as a new driverless printer. `discover.sh` skips adverts from the host's own addresses (`hostname -I`; the add-on runs on the host network).
- **CUPS gives a job up after `JobRetryLimit` retries** (default 5 x 30 s). A printer switched on by an automation needs longer to boot, so `cupsd.conf` sets 40 (20 min).
- **A dnssd URI needs the service name URL-encoded** (`HP%20Laser%20(x)`), not avahi's `\032` escapes. The stored `device` identity keeps the avahi form for compatibility; only the print `uri` is encoded.

## Tests

- `tests/` (pytest) runs the integration in a real Home Assistant core: `pip install -r requirements_test.txt && pytest`. `tests/test_entities.py` snapshots every entity (ID, unique ID, name, icon, state); it must not change, because existing installs' automations and dashboards depend on it.
- `tests/addon/` (bats) tests the shell helpers, with `snmpget`, `lpinfo` and `curl` faked: `bats tests/addon`. Each trap above that is a pure function (field separators, avahi escapes, SNMP by OID) has a test.
- shellcheck at warning level is blocking in CI.
- A Home Assistant beta can be tested by installing the newest `pytest-homeassistant-custom-component` with `homeassistant==<beta>` as an override. As of 2026.11.0b5 that needs `import homeassistant` before pytest (it aliases `httpx`) and one moved import in the plugin (`_clear_logger_overwrites`, now in `homeassistant.components.logger.helpers`).

## Home Assistant versions

Tested on 2026.10.4 and 2026.11.0b5.

- `async_setup_entry` and `async_unload_entry` still return `True`: 2026.11 wants `None` (and ignores a boolean from a custom integration), but before 2026.11 `None` means the setup failed. Switch once 2026.11 is the minimum.
- A repair is tied to its config entry (`config_entry_id`) only where `ir.async_create_issue` takes it (2026.11); `__init__.py` checks the signature.
- 2026.11 replaces HACS with the built-in **Marketplace**. It reads the same `hacs.json`; a custom repository is added with Settings > Marketplace > Add from link. Its "apps" refusal only matches `home-assistant/addons` and `hassio-addons/*`, so this repository (integration plus add-on) is accepted.

## Decided against

Do not build these again without asking the owner:

- **Power control** (switching the printer on for a job and off when idle, for plugs and button pressers). Shipped in 1.15.0, removed in 1.15.1: the owner's own automation does more (a dashboard toggle that follows the printer's power button, retrying a missed press, notifications), and two pressers acting on one job switch a printer straight back off. The README's automation example covers the simple case; the Queue sensor is what automations trigger on.
- **Live progress notifications** for print jobs: most jobs finish in seconds, and CUPS cannot tell which person sent a job (iOS prints anonymously).
- **Job events and cancel/resume/test-page buttons:** not worth it unless stuck queues become a problem; jobs are retried for 20 minutes.
- **Splitting `monitor.sh`'s scan into smaller functions:** a bash refactor risks the quoting and field bugs above for no change in behaviour.

## Security scanning

`.github/workflows/security.yml` builds the image and scans it with Trivy (official `aquasec/trivy` image; the trivy-action install script failed to download) on every push, pull request and weekly. It fails only on **fixable** HIGH/CRITICAL findings and uploads the full report to Security > Code scanning. The Dockerfile runs `apt-get upgrade`, so a rebuild (any release) takes Debian's current security updates; when the weekly scan fails, cut a release.

Most open alerts have **no fix in Debian bookworm** (nor trixie). Checked 2026-11-04 for the network-facing CUPS ones:

- **CVE-2026-34980** (fixed in CUPS 2.4.17, Debian sid/forky only): needs a shared **PostScript** queue. Driverless queues here are PWG raster.
- **CVE-2026-55453** (fixed in 2.4.20, sid only): needs a **Foomatic** queue and a malicious printer on the network feeding status messages.
- **CVE-2024-47850**: cups-browsed, which is not installed (the alert comes from `libfontembed1`, built from the same source).

cupsd only accepts the local network (`Allow @LOCAL`). Moving to Debian testing would fix these but trades a stable base for a moving one; revisit when a stable release ships CUPS >= 2.4.20.
