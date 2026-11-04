#!/usr/bin/env bash
# Sourced by run.sh and monitor.sh.
#
# match FOUND DEVICE QUEUE -> prints "DRIVER<TAB>URI" for a configured printer.
#   FOUND  - JSON from discover.sh
#   DEVICE - the printer's identity as stored by the integration
#   QUEUE  - its CUPS queue name
#
# Uses the live discovery first. A driverless printer that is switched off is
# not on the network, so fall back to the PPD and URI saved by queue.sh.

DRIVERLESS_CACHE=/config/driverless

match() {
	local found=$1 device=$2 queue=$3 row driver uri

	row=$(printf '%s' "${found}" | jq -r --arg d "${device}" \
		'.[] | select(.device == $d) | [(.driver // ""), (.uri // .device)] | @tsv' | head -1)
	IFS=$'\t' read -r driver uri <<< "${row}"

	if [ -z "${driver:-}" ] && [ -f "${DRIVERLESS_CACHE}/${queue}.ppd" ] && [ -f "${DRIVERLESS_CACHE}/${queue}.uri" ]; then
		driver=everywhere
		uri=$(cat "${DRIVERLESS_CACHE}/${queue}.uri")
	fi

	printf '%s\t%s\n' "${driver:-}" "${uri:-${device}}"
}
