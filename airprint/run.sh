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

install -m 0644 /usr/share/airprint/cupsd.conf /etc/cups/cupsd.conf

if grep -q '^SystemGroup' /etc/cups/cups-files.conf 2>/dev/null; then
	sed -i 's/^SystemGroup.*/SystemGroup root lpadmin/' /etc/cups/cups-files.conf
else
	echo 'SystemGroup root lpadmin' >> /etc/cups/cups-files.conf
fi

# Every long-running service is a child of this script, so it can tell when
# one stops (see the end).
SERVICES=()

wait_for() {
	for _ in $(seq 1 30); do
		"$@" >/dev/null 2>&1 && return 0
		sleep 1
	done
	return 1
}

mkdir -p /run/dbus
rm -f /run/dbus/pid
dbus-daemon --system --nofork &
SERVICES+=($!)
wait_for test -S /run/dbus/system_bus_socket

avahi-daemon --no-chroot &
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
	while cut -f1 "${QUEUES}" | grep -qxF "${QUEUE}"; do
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

	IFS=$'\t' read -r DRIVER URI < <(match "${FOUND}" "${DEVICE}" "${QUEUE}")

	if [ -z "${PRINTER_ICON}" ]; then
		LABEL="${NAME}"
	else
		LABEL="${PRINTER_ICON} ${NAME}"
	fi

	if [ -z "${DRIVER}" ]; then
		echo "[airprint] ${NAME}: no driver matched yet - will keep trying"
		printf '%s\t%s\t%s\t%s\t%s\n' "${QUEUE}" "${DEVICE}" "${LABEL}" "${LOCATION}" "" >> "${QUEUES}"
		continue
	fi

	echo "[airprint] ${NAME}: driver ${DRIVER}"

	if ! /queue.sh "${QUEUE}" "${URI}" "${LABEL}" "${LOCATION}" "${DRIVER}"; then
		echo "[airprint] ${NAME}: could not create the print queue - will keep trying"
		printf '%s\t%s\t%s\t%s\t%s\n' "${QUEUE}" "${DEVICE}" "${LABEL}" "${LOCATION}" "" >> "${QUEUES}"
		continue
	fi

	printf '%s\t%s\t%s\t%s\t%s\n' "${QUEUE}" "${DEVICE}" "${LABEL}" "${LOCATION}" "${DRIVER}" >> "${QUEUES}"
	echo "[airprint] ${LABEL} -> ${URI}"
done

cupsctl --share-printers

/monitor.sh &
SERVICES+=($!)
python3 -m http.server 8099 --directory /srv --bind 0.0.0.0 >/dev/null 2>&1 &
SERVICES+=($!)
avahi-publish -s "AirPrint add-on" _airprint-status._tcp 8099 >/dev/null 2>&1 &
SERVICES+=($!)

# If any service stops, stop the add-on too: the Supervisor's watchdog then
# restarts it whole. Running on without Avahi, the status feed or the monitor
# looks healthy but hides the printer from phones or freezes its sensors.
wait -n "${SERVICES[@]}" || true
echo "[airprint] a service stopped - exiting so the Supervisor restarts the add-on"
exit 1
