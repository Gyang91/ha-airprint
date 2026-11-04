#!/usr/bin/env bash
set -euo pipefail

OPTIONS=/data/options.json
QUEUES=/tmp/airprint-queues
STATUS_DIR=/srv

# shellcheck source=match.sh
. /match.sh

/drivers.sh

pkill -x cupsd 2>/dev/null && sleep 2
rm -f /run/cups/cupsd.pid

# Extra networks allowed to print (not to administer), e.g. a VPN subnet. The
# Supervisor already checks the format; check again, since it lands in cupsd.conf.
ALLOW=""
for NET in $(jq -r '.networks // [] | .[]' "${OPTIONS}"); do
	if [[ "${NET}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
		ALLOW="${ALLOW}  Allow ${NET}\n"
		echo "[airprint] printing allowed from ${NET}"
	else
		echo "[airprint] ignoring network ${NET}: use a CIDR like 192.168.3.0/24"
	fi
done
awk -v allow="${ALLOW}" '/# @NETWORKS@/ { printf "%s", allow; next } { print }' \
	/usr/share/airprint/cupsd.conf > /etc/cups/cupsd.conf

# Keep CUPS' self-signed TLS certificate across updates: an iPhone printing
# over a VPN uses TLS (the profile's ForceTLS), and a new certificate on every
# new container is a needless change of identity.
mkdir -p /config/ssl
sed -i '/^ServerKeychain/d' /etc/cups/cups-files.conf 2>/dev/null || true
echo 'ServerKeychain /config/ssl' >> /etc/cups/cups-files.conf

if grep -q '^SystemGroup' /etc/cups/cups-files.conf 2>/dev/null; then
	sed -i 's/^SystemGroup.*/SystemGroup root lpadmin/' /etc/cups/cups-files.conf
else
	echo 'SystemGroup root lpadmin' >> /etc/cups/cups-files.conf
fi

# The services printing depends on (dbus, Avahi, cupsd) are children of this
# script; if one stops, the add-on exits and the Supervisor watchdog restarts
# it (see the end). The helpers (monitor, status feed, its advert) are not
# needed to print, so they are restarted in place instead: a bug in one of
# them must never take printing down.
SERVICES=()

wait_for() {
	for _ in $(seq 1 30); do
		"$@" >/dev/null 2>&1 && return 0
		sleep 1
	done
	echo "[airprint] gave up waiting for: $*"
	return 1
}

keep_running() {
	while true; do
		"$@" || true
		echo "[airprint] $1 stopped - restarting it in 10 s"
		sleep 10
	done
}

mkdir -p /run/dbus
rm -f /run/dbus/pid
dbus-daemon --system --nofork &
SERVICES+=($!)
wait_for test -S /run/dbus/system_bus_socket

# --syslog: in the foreground Avahi logs every interface change to the add-on
# log; daemonized it went to syslog (which the container does not keep).
avahi-daemon --no-chroot --syslog &
SERVICES+=($!)
wait_for avahi-daemon --check

cupsd -f &
SERVICES+=($!)

for _ in $(seq 1 60); do
	if lpstat -r 2>/dev/null | grep -q "is running"; then
		break
	fi
	sleep 1
done

if ! lpstat -r 2>/dev/null | grep -q "is running"; then
	echo "[airprint] cupsd failed to start"
	exit 1
fi

mkdir -p "${STATUS_DIR}"
echo '{"printers":[],"discovered":[],"slug":""}' > "${STATUS_DIR}/status.json"
: > "${QUEUES}"

COUNT=$(jq '.printers | length' "${OPTIONS}")
if [ "${COUNT}" -eq 0 ]; then
	echo "[airprint] no printers configured yet — add one in Home Assistant"
fi

FOUND=$(/discover.sh)

for i in $(seq 0 $((COUNT - 1))); do
	NAME=$(jq -r ".printers[${i}].name" "${OPTIONS}")
	DEVICE=$(jq -r ".printers[${i}].device // \"\"" "${OPTIONS}")
	LOCATION=$(jq -r ".printers[${i}].location // \"\"" "${OPTIONS}")
	PRINTER_ICON=$(jq -r ".printers[${i}].icon // \"\"" "${OPTIONS}")

	QUEUE=$(printf '%s' "${NAME}" | tr -cs 'A-Za-z0-9_-' '_' | sed -e 's/^_*//' -e 's/_*$//')
	if [ -z "${QUEUE}" ]; then
		echo "[airprint] skipping printer ${i}: the name needs letters or numbers"
		continue
	fi

	SUFFIX=2
	BASE="${QUEUE}"
	while cut -d "${SEP}" -f1 "${QUEUES}" | grep -qxF "${QUEUE}"; do
		QUEUE="${BASE}_${SUFFIX}"
		SUFFIX=$((SUFFIX + 1))
	done

	if [ -z "${DEVICE}" ]; then
		DEVICE=$(printf '%s' "${FOUND}" | jq -r '.[0].device // ""')
	elif ! printf '%s' "${DEVICE}" | grep -q '://'; then
		DEVICE="socket://${DEVICE}"
	fi

	if [ -z "${DEVICE}" ]; then
		echo "[airprint] skipping ${NAME}: no printer found on the network"
		continue
	fi

	IFS="${SEP}" read -r DRIVER URI < <(match "${FOUND}" "${DEVICE}" "${QUEUE}")

	if [ -z "${PRINTER_ICON}" ]; then
		LABEL="${NAME}"
	else
		LABEL="${PRINTER_ICON} ${NAME}"
	fi

	if [ -z "${DRIVER}" ]; then
		echo "[airprint] ${NAME}: no driver matched yet - will keep trying"
		row "${QUEUE}" "${DEVICE}" "${LABEL}" "${LOCATION}" "" >> "${QUEUES}"
		continue
	fi

	echo "[airprint] ${NAME}: driver ${DRIVER}"

	if ! /queue.sh "${QUEUE}" "${URI}" "${LABEL}" "${LOCATION}" "${DRIVER}"; then
		echo "[airprint] ${NAME}: could not create the print queue - will keep trying"
		row "${QUEUE}" "${DEVICE}" "${LABEL}" "${LOCATION}" "" >> "${QUEUES}"
		continue
	fi

	row "${QUEUE}" "${DEVICE}" "${LABEL}" "${LOCATION}" "${DRIVER}" >> "${QUEUES}"
	echo "[airprint] ${LABEL} -> ${URI}"
done

cupsctl --share-printers

keep_running /monitor.sh &
keep_running python3 -m http.server 8099 --directory /srv --bind 0.0.0.0 >/dev/null 2>&1 &
keep_running avahi-publish -s "AirPrint add-on" _airprint-status._tcp 8099 >/dev/null 2>&1 &

# If a service printing depends on stops, stop the add-on too: the Supervisor's
# watchdog then restarts it whole. Running on without Avahi or cupsd looks
# healthy but hides the printer from phones or loses jobs.
wait -n "${SERVICES[@]}" || true
echo "[airprint] a service stopped - exiting so the Supervisor restarts the add-on"
exit 1
