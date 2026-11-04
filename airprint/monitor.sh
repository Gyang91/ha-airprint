#!/usr/bin/env bash
set -uo pipefail

QUEUES=/tmp/airprint-queues
# Which notifications were sent, kept in /data so a restart (every printer
# edit restarts the add-on) does not send them again after they were dismissed.
NOTIFIED=/data/airprint-notified
STATUS=/srv/status.json
CORE=http://supervisor/core/api

# Print jobs are counted every TICK seconds, so a job for a switched-off printer
# shows up fast (an automation can switch it on). The full scan - mDNS discovery,
# SNMP, driver matching - is slower and runs every SCAN_EVERY ticks.
TICK=15
SCAN_EVERY=4

# SNMP objects read in one request per printer.
OID_UPTIME=.1.3.6.1.2.1.1.3.0
OID_SUPPLY=.1.3.6.1.2.1.43.11.1.1.6.1.1
OID_CAPACITY=.1.3.6.1.2.1.43.11.1.1.8.1.1
OID_LEVEL=.1.3.6.1.2.1.43.11.1.1.9.1.1
OID_PAGES=.1.3.6.1.2.1.43.10.2.1.4.1.1

# shellcheck source=match.sh
. /match.sh

touch "${NOTIFIED}"

# "Printer needs a driver" is a repair in the integration now. Remove the
# notification older versions sent, and stop tracking it.
sed -i '/^nodriver_/d' "${NOTIFIED}"
FIRST_SCAN=true

# Logged once per add-on start, not every scan.
declare -A LOGGED=()

log_once() {
	local key=$1
	shift
	[ -n "${LOGGED[${key}]:-}" ] && return 0
	LOGGED["${key}"]=1
	echo "[airprint] $*"
}

PRINTERS="[]"
DISCOVERED="[]"
SLUG=""

# Last address seen per device. A sleeping printer sometimes misses an mDNS
# browse; it still answers SNMP at its last address, so it stays Online.
declare -A KNOWN_HOSTS=()

# Devices that answered SNMP since the add-on started. Only for these is
# silence evidence of a problem: a printer without SNMP never answers at all.
declare -A SNMP_SEEN=()

notify() {
	curl -sS -o /dev/null -m 10 \
		-H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
		-H "Content-Type: application/json" \
		-X POST -d "$(jq -nc --arg t "$1" --arg m "$2" --arg i "airprint_$3" \
			'{title:$t, message:$m, notification_id:$i}')" \
		"${CORE}/services/persistent_notification/create" || true
}

dismiss() {
	curl -sS -o /dev/null -m 10 \
		-H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
		-H "Content-Type: application/json" \
		-X POST -d "$(jq -nc --arg i "airprint_$1" '{notification_id:$i}')" \
		"${CORE}/services/persistent_notification/dismiss" || true
}

# All status objects in one request. -On prints "OID value" per line, so an
# object the printer lacks is just missing (SNMPv1 retries without it).
snmp_status() {
	snmpget -v1 -c public -t 2 -r 0 -Oqn "$1" \
		"${OID_UPTIME}" "${OID_SUPPLY}" "${OID_CAPACITY}" "${OID_LEVEL}" "${OID_PAGES}" 2>/dev/null
}

# snmp_value SNMP_OUTPUT OID -> the value, without quotes.
snmp_value() {
	printf '%s\n' "$1" | awk -v oid="$2" '$1 == oid { $1 = ""; sub(/^ /, ""); gsub(/"/, ""); print; exit }'
}

error_reasons() {
	local hex
	hex=$(snmpget -v1 -c public -t 2 -r 0 -Oqvx "$1" 1.3.6.1.2.1.25.3.5.1.2.1 2>/dev/null | tr -cd '0-9A-Fa-f')
	[ -n "${hex}" ] || return 0

	local bits=$((16#${hex:0:2}))
	local reasons=()

	((bits & 0x80)) && reasons+=("Paper low")
	((bits & 0x40)) && reasons+=("Out of paper")
	((bits & 0x20)) && reasons+=("Toner low")
	((bits & 0x10)) && reasons+=("Out of toner")
	((bits & 0x08)) && reasons+=("Door open")
	((bits & 0x04)) && reasons+=("Paper jam")
	((bits & 0x02)) && reasons+=("Offline")
	((bits & 0x01)) && reasons+=("Needs attention")

	printf '%s\n' "${reasons[@]}"
}

# Waiting jobs per queue, as JSON: {"Drucker_B_ro": 1}. One lpstat for all queues.
job_counts() {
	lpstat -o 2>/dev/null |
		awk '{ sub(/-[0-9]+$/, "", $1); n[$1]++ } END { for (q in n) print q "\t" n[q] }' |
		jq -Rn '[inputs | split("\t") | {(.[0]): (.[1] | tonumber)}] | add // {}'
}

# The printer's address. discover.sh already resolved every dnssd printer, so
# only a socket:// printer (entered as an IP) is parsed here.
host_of() {
	local device=$1 found=$2 hostport
	case "${device}" in
	dnssd://*)
		printf '%s' "${found}" | jq -r --arg d "${device}" '.[] | select(.device == $d) | .address' | head -1
		;;
	socket://*)
		hostport=${device#socket://}
		hostport=${hostport%%/*}
		printf '%s' "${hostport%%:*}"
		;;
	esac
}

# printer_state DEVICE ADVERTISED ANSWERED -> sets ONLINE and PROBLEM.
# ANSWERED is true when SNMP sysUpTime answered this scan.
printer_state() {
	local device=$1 advertised=$2 answered=$3
	if [ "${answered}" = "true" ]; then
		SNMP_SEEN["${device}"]=1
		ONLINE=true
		PROBLEM=false
	elif [ "${advertised}" = "true" ] && [ -n "${SNMP_SEEN["${device}"]:-}" ]; then
		# Answered SNMP before, still on the network, silent now: stuck or
		# showing an error.
		ONLINE=true
		PROBLEM=true
	elif [ "${advertised}" = "true" ]; then
		# No SNMP agent (or it is off): the advert is all we know.
		ONLINE=true
		PROBLEM=false
	else
		ONLINE=false
		PROBLEM=false
	fi
}

scan() {
	local found configured="" jobs_by_queue
	local QUEUE DEVICE LABEL LOCATION DRIVER MATCH URI HOST ADVERTISED SNMP ANSWERED ONLINE PROBLEM JOBS MODEL
	local TONER SUPPLY PAGES REASONS LEVEL CAPACITY COUNT WHY ROW NAME SERVICE ID

	found=$(/discover.sh)
	jobs_by_queue=$(job_counts)
	PRINTERS="[]"

	: > "${QUEUES}.next"

	while IFS="${SEP}" read -r QUEUE DEVICE LABEL LOCATION DRIVER; do
		[ -n "${QUEUE}" ] || continue
		configured="${configured} ${DEVICE}"
		LOCATION=${LOCATION:-}
		DRIVER=${DRIVER:-}

		# The one place queues are created: at start (run.sh only lists the
		# printers) and whenever a printer that had no driver gets one.
		if [ -z "${DRIVER}" ]; then
			IFS="${SEP}" read -r MATCH URI < <(match "${found}" "${DEVICE}" "${QUEUE}")
			if [ -z "${MATCH}" ]; then
				log_once "nodriver_${QUEUE}" "${LABEL}: no driver matched yet - will keep trying"
			elif /queue.sh "${QUEUE}" "${URI}" "${LABEL}" "${LOCATION}" "${MATCH}"; then
				echo "[airprint] ${LABEL}: driver ${MATCH} -> queue created (${URI})"
				DRIVER=${MATCH}
			else
				log_once "noqueue_${QUEUE}" "${LABEL}: could not create the print queue - will keep trying"
			fi
		fi

		# In the background: Home Assistant may not be up yet, and this
		# must not hold up the first status report.
		if [ "${FIRST_SCAN}" = "true" ]; then
			dismiss "nodriver_${QUEUE}" &
		fi

		row "${QUEUE}" "${DEVICE}" "${LABEL}" "${LOCATION}" "${DRIVER}" >> "${QUEUES}.next"

		HOST=$(host_of "${DEVICE}" "${found}")
		ADVERTISED=true
		if [ -n "${HOST}" ]; then
			KNOWN_HOSTS["${DEVICE}"]=${HOST}
		else
			HOST=${KNOWN_HOSTS["${DEVICE}"]:-}
			ADVERTISED=false
		fi

		SNMP=""
		[ -n "${HOST}" ] && SNMP=$(snmp_status "${HOST}")

		ANSWERED=false
		[ -n "$(snmp_value "${SNMP}" "${OID_UPTIME}")" ] && ANSWERED=true
		printer_state "${DEVICE}" "${ADVERTISED}" "${ANSWERED}"
		[ "${ONLINE}" = "true" ] || HOST=""

		JOBS=$(printf '%s' "${jobs_by_queue}" | jq --arg q "${QUEUE}" '.[$q] // 0')
		MODEL=$(printf '%s' "${found}" | jq -r --arg d "${DEVICE}" '.[] | select(.device == $d) | .name' | head -1)

		TONER=null
		SUPPLY=""
		PAGES=null
		REASONS="[]"

		# Only a printer that answered: another SNMP read of one without an
		# agent would just wait out its timeout every scan.
		if [ "${ANSWERED}" = "true" ]; then
			SUPPLY=$(snmp_value "${SNMP}" "${OID_SUPPLY}")
			LEVEL=$(snmp_value "${SNMP}" "${OID_LEVEL}")
			CAPACITY=$(snmp_value "${SNMP}" "${OID_CAPACITY}")
			COUNT=$(snmp_value "${SNMP}" "${OID_PAGES}")

			if [ -n "${LEVEL}" ] && [ -n "${CAPACITY}" ] && [ "${CAPACITY}" -gt 0 ] 2>/dev/null; then
				TONER=$((LEVEL * 100 / CAPACITY))
			fi
			[ -n "${COUNT}" ] && [ "${COUNT}" -ge 0 ] 2>/dev/null && PAGES=${COUNT}

			REASONS=$(error_reasons "${HOST}" | jq -Rc '[., inputs] | map(select(length > 0))' 2>/dev/null || echo '[]')
			[ -n "${REASONS}" ] || REASONS="[]"
		fi

		PRINTERS=$(printf '%s' "${PRINTERS}" | jq -c \
			--arg id "${QUEUE}" --arg device "${DEVICE}" --arg name "${LABEL}" --arg host "${HOST}" \
			--arg model "${MODEL}" --arg supply "${SUPPLY}" --arg driver "${DRIVER}" \
			--argjson online "${ONLINE}" --argjson problem "${PROBLEM}" --argjson jobs "${JOBS}" \
			--argjson toner "${TONER}" --argjson pages "${PAGES}" --argjson reasons "${REASONS}" \
			'. + [{id:$id, device:$device, name:$name, model:$model, driver:$driver, host:$host, online:$online, problem:$problem, jobs:$jobs, toner:$toner, supply:$supply, pages:$pages, reasons:$reasons}]')

		if [ "${PROBLEM}" = "true" ] && [ "${JOBS}" -gt 0 ]; then
			if ! grep -qx "stuck_${QUEUE}" "${NOTIFIED}"; then
				echo "stuck_${QUEUE}" >> "${NOTIFIED}"
				WHY=$(printf '%s' "${REASONS}" | jq -r 'join(", ")')
				[ -n "${WHY}" ] || WHY="It is usually out of paper, jammed, or showing an error"
				notify "Printer not accepting jobs" \
					"**${LABEL}** is refusing print jobs and ${JOBS} job(s) are waiting. ${WHY}." \
					"stuck_${QUEUE}"
			fi
		elif [ "${PROBLEM}" = "false" ]; then
			if grep -qx "stuck_${QUEUE}" "${NOTIFIED}"; then
				sed -i "/^stuck_${QUEUE}$/d" "${NOTIFIED}"
				dismiss "stuck_${QUEUE}"
			fi
		fi
	done < "${QUEUES}"

	mv "${QUEUES}.next" "${QUEUES}"
	FIRST_SCAN=false

	DISCOVERED="[]"

	while read -r ROW; do
		[ -n "${ROW}" ] || continue
		DEVICE=$(printf '%s' "${ROW}" | jq -r '.device')
		NAME=$(printf '%s' "${ROW}" | jq -r '.name')

		case " ${configured} " in
		*" ${DEVICE} "*) continue ;;
		esac

		# Same Bonjour name as a configured printer, another service type: the
		# same printer. While it switches off, its _pdl-datastream advert goes
		# first and the _ipp one lingers, which looked like a new IPP-only printer.
		SERVICE=${DEVICE#dnssd://}
		SERVICE=${SERVICE%%._*}
		case " ${configured} " in
		*"dnssd://${SERVICE}._"*) continue ;;
		esac

		DISCOVERED=$(printf '%s' "${DISCOVERED}" | jq -c --argjson found "${ROW}" '. + [$found]')

		ID=$(printf '%s' "${DEVICE}" | tr -cs 'A-Za-z0-9' '_')
		grep -qx "new_${ID}" "${NOTIFIED}" && continue
		echo "new_${ID}" >> "${NOTIFIED}"
		notify "New printer found" \
			"**${NAME}** is on your network but is not set up. Add it under Settings → Devices & Services → AirPrint." \
			"new_${ID}"
	done < <(printf '%s' "${found}" | jq -c '.[]')

	# The slug never changes while the add-on runs.
	[ -n "${SLUG}" ] || SLUG=$(curl -sS -m 10 -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" http://supervisor/addons/self/info 2>/dev/null | jq -r '.data.slug // ""')
}

# Between scans only the job counts change.
refresh_jobs() {
	PRINTERS=$(printf '%s' "${PRINTERS}" | jq -c --argjson jobs "$(job_counts)" 'map(.jobs = ($jobs[.id] // 0))')
}

# Written only when something changed: most ticks change nothing, and this is
# the add-on's disk. A failed jq must not replace the feed with an empty file.
write_status() {
	local status
	status=$(jq -nc --argjson printers "${PRINTERS}" --argjson discovered "${DISCOVERED}" --arg slug "${SLUG}" \
		'{printers:$printers, discovered:$discovered, slug:$slug}') || return 0
	[ "${status}" = "$(cat "${STATUS}" 2>/dev/null)" ] && return 0
	printf '%s\n' "${status}" > "${STATUS}.tmp"
	mv "${STATUS}.tmp" "${STATUS}"
}

TICKS=0
while true; do
	if [ $((TICKS % SCAN_EVERY)) -eq 0 ]; then
		scan
	else
		refresh_jobs
	fi
	write_status
	TICKS=$((TICKS + 1))
	sleep "${TICK}"
done
