#!/usr/bin/env bash
set -uo pipefail

# Lists the printers on the network as JSON:
#   [{device, uri, name, address, device_id, driver}]
#
# device  - the printer's identity, stored in the integration. Always the
#           _pdl-datastream Bonjour name when the printer has one, so existing
#           setups keep matching.
# uri     - where CUPS sends jobs. The same as device for a PPD driver; the
#           printer's _ipp._tcp Bonjour name for a driverless queue.
# driver  - a PPD from the local database, or "everywhere" (IPP Everywhere,
#           driverless) when no PPD matches but the printer speaks AirPrint/IPP
#           raster. Empty when neither works.
#
# Passive mDNS only: never run CUPS device discovery (lpinfo -v), it opens 9100.

driver_for() {
	local device_id=$1 model=$2 driver=""

	if [ -n "${device_id}" ]; then
		driver=$(lpinfo --device-id "${device_id}" -m 2>/dev/null | awk 'NR == 1 { print $1 }')
	fi

	if [ -z "${driver}" ] && [ -n "${model}" ]; then
		driver=$(lpinfo --make-and-model "${model}" -m 2>/dev/null | awk 'NR == 1 { print $1 }')
	fi

	printf '%s' "${driver}"
}

txt_value() {
	printf '%s' "$1" | grep -o "\"$2=[^\"]*\"" | head -1 | sed "s/^\"$2=//; s/\"\$//"
}

model_of() {
	local txt=$1 service=$2 model
	model=$(txt_value "${txt}" usb_MDL)
	[ -n "${model}" ] || model=$(txt_value "${txt}" ty)
	[ -n "${model}" ] || model=$(txt_value "${txt}" product | tr -d '()')
	[ -n "${model}" ] || model="${service}"
	printf '%s' "${model}"
}

# IPP Everywhere needs a raster format CUPS can produce without a vendor driver.
driverless() {
	local txt=$1
	[ -n "$(txt_value "${txt}" URF)" ] && return 0
	txt_value "${txt}" pdl | grep -qE 'image/(urf|pwg-raster)'
}

browse() {
	timeout 6 avahi-browse -rtp "$1" 2>/dev/null | grep '^=' | grep ';IPv4;'
}

# Driverless-capable IPP adverts, by IPv4 address: "address<TAB>service<TAB>model".
IPP=""
while IFS=';' read -r _ _ _ SERVICE _ _ _ IP _ TXT; do
	[ -n "${SERVICE}" ] || continue
	driverless "${TXT}" || continue
	IPP="${IPP}${IP}	${SERVICE}	$(model_of "${TXT}" "${SERVICE}")
"
done < <(browse _ipp._tcp)

ipp_for() {
	printf '%s' "${IPP}" | awk -F'\t' -v ip="$1" '$1 == ip { print $2; exit }'
}

FOUND="[]"
SEEN=" "

add() {
	FOUND=$(printf '%s' "${FOUND}" | jq -c \
		--arg device "$1" --arg uri "$2" --arg name "$3" --arg address "$4" \
		--arg id "$5" --arg driver "$6" \
		'. + [{device:$device, uri:$uri, name:$name, address:$address, device_id:$id, driver:$driver}]')
}

while IFS=';' read -r _ _ _ SERVICE _ _ _ IP _ TXT; do
	[ -n "${SERVICE}" ] || continue

	MFG=$(txt_value "${TXT}" usb_MFG)
	MDL=$(txt_value "${TXT}" usb_MDL)
	MODEL=$(model_of "${TXT}" "${SERVICE}")

	DEVICE_ID=""
	[ -n "${MFG}" ] && DEVICE_ID="MFG:${MFG};"
	[ -n "${MDL}" ] && DEVICE_ID="${DEVICE_ID}MDL:${MDL};"

	DEVICE="dnssd://${SERVICE}._pdl-datastream._tcp.local/"
	URI="${DEVICE}"
	DRIVER=$(driver_for "${DEVICE_ID}" "${MODEL}")

	if [ -z "${DRIVER}" ]; then
		IPP_SERVICE=$(ipp_for "${IP}")
		if [ -n "${IPP_SERVICE}" ]; then
			DRIVER=everywhere
			URI="dnssd://${IPP_SERVICE}._ipp._tcp.local/"
		fi
	fi

	add "${DEVICE}" "${URI}" "${MODEL}" "${IP}" "${DEVICE_ID}" "${DRIVER}"
	SEEN="${SEEN}${IP} "
done < <(browse _pdl-datastream._tcp)

# Printers that only advertise IPP (no raw port) can still print driverless.
while IFS=$'\t' read -r IP SERVICE MODEL; do
	[ -n "${IP}" ] || continue
	case "${SEEN}" in *" ${IP} "*) continue ;; esac
	DEVICE="dnssd://${SERVICE}._ipp._tcp.local/"
	add "${DEVICE}" "${DEVICE}" "${MODEL}" "${IP}" "" everywhere
	SEEN="${SEEN}${IP} "
done < <(printf '%s' "${IPP}")

printf '%s' "${FOUND}" | jq -c 'unique_by(.device)'
