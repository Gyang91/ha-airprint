#!/usr/bin/env bash
set -uo pipefail

QUEUE=$1
URI=$2
LABEL=$3
LOCATION=$4
DRIVER=$5

# Driverless (IPP Everywhere) PPDs are built by asking the printer itself, so
# they can only be made while it is on. Keep the last one in the add-on's
# config folder, so the queue comes back after a restart even if the printer
# is switched off then (jobs wait in the queue until it is back).
CACHE=/config/driverless

if [ "${DRIVER}" = "everywhere" ]; then
	# cups-filters builds the PPD in its own process from the printer's IPP
	# attributes (port 631). Not "lpadmin -m everywhere": that makes cupsd 2.4.2
	# (bookworm) build it and crash with "free(): invalid pointer".
	# A Bonjour printer's URI is dnssd://<name>._ipp._tcp.local/; one added by
	# IP is already ipp://<address>/ipp/print.
	case "${URI}" in
	dnssd://*) IPP_URI="ipp://${URI#dnssd://}" ;;
	*) IPP_URI=${URI} ;;
	esac
	mkdir -p "${CACHE}"
	if /usr/lib/cups/driver/driverless cat "driverless:${IPP_URI}" > "${CACHE}/${QUEUE}.ppd.new" 2>/dev/null &&
		grep -q '^\*PPD-Adobe' "${CACHE}/${QUEUE}.ppd.new"; then
		mv "${CACHE}/${QUEUE}.ppd.new" "${CACHE}/${QUEUE}.ppd"
		printf '%s\n' "${URI}" > "${CACHE}/${QUEUE}.uri"
	else
		rm -f "${CACHE}/${QUEUE}.ppd.new"
		[ -f "${CACHE}/${QUEUE}.ppd" ] || exit 1
		echo "[airprint] ${LABEL}: printer not reachable - using its saved driverless PPD"
	fi
	MODEL=(-P "${CACHE}/${QUEUE}.ppd")
else
	MODEL=(-m "${DRIVER}")
fi

lpadmin -p "${QUEUE}" \
	-v "${URI}" \
	"${MODEL[@]}" \
	-D "${LABEL}" \
	-L "${LOCATION}" \
	-o printer-is-shared=true \
	-o printer-error-policy=retry-job \
	-E || exit 1

mkdir -p /var/cache/cups/images
cp /usr/share/airprint/printer.png "/var/cache/cups/images/${QUEUE}.png"
