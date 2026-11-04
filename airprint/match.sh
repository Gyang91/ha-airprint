#!/usr/bin/env bash
# Sourced by run.sh, monitor.sh and discover.sh.
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

# Each "lpinfo -m" reads the whole PPD database (about a second), for every
# printer on every scan. The database only changes when drivers.sh runs, at
# add-on start, so each answer is kept in /tmp for the life of the container.
MATCHES=/tmp/airprint-matches

# lpinfo_model OPTION VALUE -> the best matching model, or nothing.
lpinfo_model() {
	local file out
	file="${MATCHES}/$(printf '%s\n%s' "$1" "$2" | md5sum | cut -d' ' -f1)"

	if [ -f "${file}" ]; then
		cat "${file}"
		return
	fi

	mkdir -p "${MATCHES}"
	if out=$(lpinfo "$1" "$2" -m 2>"${file}.err") && [ -n "${out}" ]; then
		out=$(printf '%s\n' "${out}" | awk 'NR == 1 { print $1 }')
	elif grep -q 'not-found' "${file}.err"; then
		out=""
	else
		# cupsd did not answer (or said nothing): ask again next scan.
		rm -f "${file}.err"
		return
	fi

	rm -f "${file}.err"
	printf '%s' "${out}" > "${file}"
	printf '%s' "${out}"
}

# driver_for DEVICE_ID MODEL -> a PPD from the local database, or nothing.
driver_for() {
	local device_id=$1 model=$2 driver=""

	if [ -n "${device_id}" ]; then
		driver=$(lpinfo_model --device-id "${device_id}")
	fi

	if [ -z "${driver}" ] && [ -n "${model}" ]; then
		driver=$(lpinfo_model --make-and-model "${model}")
	fi

	printf '%s' "${driver}"
}

# snmp_value SNMP_OUTPUT OID -> the value, without quotes.
snmp_value() {
	printf '%s\n' "$1" | awk -v oid="$2" '$1 == oid { $1 = ""; sub(/^ /, ""); gsub(/"/, ""); print; exit }'
}

# socket_host socket://HOST[:PORT][/] -> HOST.
socket_host() {
	local hostport=${1#socket://}
	hostport=${hostport%%/*}
	printf '%s' "${hostport%%:*}"
}

# A printer added by its IP address has no Bonjour advert to read its model
# from. SNMP has it (UDP 161, never the print port): the IEEE 1284 device ID
# from the PWG Port Monitor MIB (vendor-neutral, what CUPS' own snmp backend
# reads) or HP's private one, and hrDeviceDescr as the make and model.
OID_DEVICE_ID=.1.3.6.1.4.1.2699.1.2.1.2.1.1.3.1
OID_HP_DEVICE_ID=.1.3.6.1.4.1.11.2.3.9.1.1.7.0
OID_DESCR=.1.3.6.1.2.1.25.3.2.1.3.1

# snmp_identity HOST -> row DEVICE_ID MODEL (either may be empty).
snmp_identity() {
	local out id model
	# One request; -Oa prints strings as text (a device ID can start with its
	# two binary length bytes), -Oqn as "OID value" so values match by OID.
	out=$(snmpget -v1 -c public -t 2 -r 0 -Oqna "$1" \
		"${OID_DEVICE_ID}" "${OID_HP_DEVICE_ID}" "${OID_DESCR}" 2>/dev/null)

	id=$(snmp_value "${out}" "${OID_DEVICE_ID}")
	[ -n "${id}" ] || id=$(snmp_value "${out}" "${OID_HP_DEVICE_ID}")
	# Drop the length bytes (printed as dots) before the first key.
	id=$(printf '%s' "${id}" | sed 's/^[^A-Za-z]*//')
	model=$(snmp_value "${out}" "${OID_DESCR}")

	row "${id}" "${model}"
}

# ipp_answers HOST -> true if something listens on the IPP port (631).
ipp_answers() {
	timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/631"' _ "$1" 2>/dev/null
}

# ip_match DEVICE -> row DRIVER URI for a socket:// printer, or nothing.
# A PPD matched from its SNMP identity prints to the raw port (a real job is
# the only thing that connects there). Otherwise a printer that answers IPP
# prints driverless; queue.sh builds its PPD from the printer.
ip_match() {
	local device=$1 host id model driver
	host=$(socket_host "${device}")
	[ -n "${host}" ] || return 0

	IFS="${SEP}" read -r id model < <(snmp_identity "${host}")
	driver=$(driver_for "${id:-}" "${model:-}")
	# cups-filters' driverless listing is not a PPD (see discover.sh).
	case "${driver}" in driverless:*) driver="" ;; esac

	if [ -n "${driver}" ]; then
		row "${driver}" "${device}"
	elif ipp_answers "${host}"; then
		row everywhere "ipp://${host}/ipp/print"
	fi
}

# match FOUND DEVICE QUEUE -> prints row DRIVER URI for a configured printer.
#   FOUND  - JSON from discover.sh
#   DEVICE - the printer's identity as stored by the integration
#   QUEUE  - its CUPS queue name
#
# Uses the live discovery first (or, for a printer added by IP, SNMP and IPP).
# A driverless printer that is switched off is not on the network, so fall
# back to the PPD and URI saved by queue.sh.

DRIVERLESS_CACHE=/config/driverless

match() {
	local found=$1 device=$2 queue=$3 line driver uri

	case "${device}" in
	socket://*) line=$(ip_match "${device}") ;;
	*)
		line=$(printf '%s' "${found}" | jq -r --arg d "${device}" --arg sep "${SEP}" \
			'.[] | select(.device == $d) | [(.driver // ""), (.uri // .device)] | join($sep)' | head -1)
		;;
	esac
	IFS="${SEP}" read -r driver uri <<< "${line}"

	if [ -z "${driver:-}" ] && [ -f "${DRIVERLESS_CACHE}/${queue}.ppd" ] && [ -f "${DRIVERLESS_CACHE}/${queue}.uri" ]; then
		driver=everywhere
		uri=$(cat "${DRIVERLESS_CACHE}/${queue}.uri")
	fi

	row "${driver:-}" "${uri:-${device}}"
}
