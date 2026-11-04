#!/usr/bin/env bash
# Sourced by run.sh and monitor.sh.
#
# Fields passed between them are separated by SEP (ASCII unit separator), never
# a tab: "read" with IFS=tab collapses an empty field (tab is whitespace to
# IFS), so an empty location or driver shifted the next field into it.
SEP=$'\x1f'

# row FIELD... -> the fields joined by SEP, one line.
row() {
	local IFS="${SEP}"
	printf '%s\n' "$*"
}

# match FOUND DEVICE QUEUE -> prints row DRIVER URI for a configured printer.
#   FOUND  - JSON from discover.sh
#   DEVICE - the printer's identity as stored by the integration
#   QUEUE  - its CUPS queue name
#
# Uses the live discovery first. A driverless printer that is switched off is
# not on the network, so fall back to the PPD and URI saved by queue.sh.

DRIVERLESS_CACHE=/config/driverless

match() {
	local found=$1 device=$2 queue=$3 line driver uri

	line=$(printf '%s' "${found}" | jq -r --arg d "${device}" --arg sep "${SEP}" \
		'.[] | select(.device == $d) | [(.driver // ""), (.uri // .device)] | join($sep)' | head -1)
	IFS="${SEP}" read -r driver uri <<< "${line}"

	if [ -z "${driver:-}" ] && [ -f "${DRIVERLESS_CACHE}/${queue}.ppd" ] && [ -f "${DRIVERLESS_CACHE}/${queue}.uri" ]; then
		driver=everywhere
		uri=$(cat "${DRIVERLESS_CACHE}/${queue}.uri")
	fi

	row "${driver:-}" "${uri:-${device}}"
}
