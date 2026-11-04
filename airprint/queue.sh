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
	mkdir -p "${CACHE}"
	if lpadmin -p "${QUEUE}" -v "${URI}" -m everywhere 2>/dev/null; then
		cp "/etc/cups/ppd/${QUEUE}.ppd" "${CACHE}/${QUEUE}.ppd" 2>/dev/null || true
		printf '%s\n' "${URI}" > "${CACHE}/${QUEUE}.uri"
		MODEL=()   # the queue already has its PPD; only set the options below
	elif [ -f "${CACHE}/${QUEUE}.ppd" ]; then
		echo "[airprint] ${LABEL}: printer not reachable - using its saved driverless PPD"
		MODEL=(-P "${CACHE}/${QUEUE}.ppd")
	else
		exit 1
	fi
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
