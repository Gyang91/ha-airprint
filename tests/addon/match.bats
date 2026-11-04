#!/usr/bin/env bats
# Fields passed between run.sh and monitor.sh (CLAUDE.md: never tab-separated).

load helpers

setup() {
	# shellcheck source=../../airprint/match.sh
	. "${ADDON}/match.sh"
	DRIVERLESS_CACHE="${BATS_TEST_TMPDIR}/driverless"
}

@test "row keeps empty fields in place" {
	line=$(row "Office" "dnssd://x" "🖨️ HP" "" "drv")
	IFS="${SEP}" read -r q d l loc drv <<< "${line}"
	[ "${q}" = "Office" ]
	[ "${l}" = "🖨️ HP" ]
	[ "${loc}" = "" ]
	[ "${drv}" = "drv" ]
}

@test "row with an empty location and driver reads back the same" {
	line=$(row "Q" "dnssd://x" "Label" "" "")
	IFS="${SEP}" read -r q d l loc drv <<< "${line}"
	[ "${d}" = "dnssd://x" ]
	[ "${l}" = "Label" ]
	[ -z "${loc}" ] && [ -z "${drv}" ]
}

@test "match takes the driver and print URI from discovery" {
	found='[{"device":"dnssd://A._pdl-datastream._tcp.local/","uri":"dnssd://A%20B._ipp._tcp.local/","driver":"everywhere"}]'
	IFS="${SEP}" read -r driver uri < <(match "${found}" "dnssd://A._pdl-datastream._tcp.local/" "Q")
	[ "${driver}" = "everywhere" ]
	[ "${uri}" = "dnssd://A%20B._ipp._tcp.local/" ]
}

@test "match: unknown printer has no driver and keeps its own URI" {
	IFS="${SEP}" read -r driver uri < <(match "[]" "socket://10.0.0.5" "Q")
	[ -z "${driver}" ]
	[ "${uri}" = "socket://10.0.0.5" ]
}

@test "match: a switched-off driverless printer uses its saved PPD" {
	mkdir -p "${DRIVERLESS_CACHE}"
	echo '*PPD-Adobe: "4.3"' > "${DRIVERLESS_CACHE}/Q.ppd"
	echo "dnssd://A._ipp._tcp.local/" > "${DRIVERLESS_CACHE}/Q.uri"
	IFS="${SEP}" read -r driver uri < <(match "[]" "dnssd://A._pdl-datastream._tcp.local/" "Q")
	[ "${driver}" = "everywhere" ]
	[ "${uri}" = "dnssd://A._ipp._tcp.local/" ]
}
