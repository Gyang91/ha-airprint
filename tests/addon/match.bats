#!/usr/bin/env bats
# Fields passed between run.sh and monitor.sh (CLAUDE.md: never tab-separated).

load helpers

setup() {
	# shellcheck source=../../airprint/match.sh
	. "${ADDON}/match.sh"
	DRIVERLESS_CACHE="${BATS_TEST_TMPDIR}/driverless"
	MATCHES="${BATS_TEST_TMPDIR}/matches"
	CALLS="${BATS_TEST_TMPDIR}/calls"
	export CALLS
	fake_bin
	# By default: no SNMP agent, nothing on the IPP port, no PPD matches.
	snmp_answers ""
	ipp_port closed
	fake lpinfo <<'EOF2'
#!/bin/bash
echo "lpinfo $*" >> "${CALLS}"
echo "lpinfo: client-error-not-found" >&2; exit 1
EOF2
}

# snmp_answers OUTPUT -> a fake snmpget that prints OUTPUT ("OID value" lines).
snmp_answers() {
	printf '%s\n' "$1" > "${BATS_TEST_TMPDIR}/snmp.out"
	fake snmpget <<'EOF2'
#!/bin/bash
echo "snmpget $*" >> "${CALLS}"
[ -s "${BATS_TEST_TMPDIR}/snmp.out" ] || exit 1
cat "${BATS_TEST_TMPDIR}/snmp.out"
EOF2
}

# ipp_port open|closed -> whether the IPP probe (run under timeout) connects.
ipp_port() {
	local code=1
	[ "$1" = open ] && code=0
	fake timeout <<EOF2
#!/bin/bash
echo "timeout \$*" >> "\${CALLS}"
exit ${code}
EOF2
}

PWG_ID=.1.3.6.1.4.1.2699.1.2.1.2.1.1.3.1
HP_ID=.1.3.6.1.4.1.11.2.3.9.1.1.7.0
DESCR=.1.3.6.1.2.1.25.3.2.1.3.1

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

@test "match: IP printer with neither SNMP nor IPP has no driver and keeps its own URI" {
	IFS="${SEP}" read -r driver uri < <(match "[]" "socket://10.0.0.5" "Q")
	[ -z "${driver}" ]
	[ "${uri}" = "socket://10.0.0.5" ]
}

@test "match: IP printer's driver comes from its SNMP device ID" {
	snmp_answers "${PWG_ID} \"MFG:Brother;CMD:PJL,PCL;MDL:HL-L2350DW series;\""
	fake lpinfo <<'EOF2'
#!/bin/bash
echo "lpinfo $*" >> "${CALLS}"
[ "$1 $2" = "--device-id MFG:Brother;CMD:PJL,PCL;MDL:HL-L2350DW series;" ] || exit 1
echo "brlaser:0/ppd/brlaser/br2350.ppd Brother HL-L2350DW series, using brlaser"
EOF2
	IFS="${SEP}" read -r driver uri < <(match "[]" "socket://10.0.0.5" "Q")
	[ "${driver}" = "brlaser:0/ppd/brlaser/br2350.ppd" ]
	[ "${uri}" = "socket://10.0.0.5" ]
	# Asked SNMP at the printer's address, nothing else.
	grep -q "^snmpget .* 10.0.0.5 ${PWG_ID} ${HP_ID} ${DESCR}\$" "${CALLS}"
}

@test "match: HP's device ID is used when the PWG one is missing, length bytes dropped" {
	snmp_answers "${HP_ID} \"..MFG:HP;MDL:LaserJet 1020;\"
${DESCR} \"HP LaserJet 1020\""
	fake lpinfo <<'EOF2'
#!/bin/bash
echo "lpinfo $*" >> "${CALLS}"
[ "$1 $2" = "--device-id MFG:HP;MDL:LaserJet 1020;" ] || exit 1
echo "foo2zjs:0/ppd/foo2zjs/HP-LaserJet_1020.ppd HP LaserJet 1020 Foomatic"
EOF2
	IFS="${SEP}" read -r driver uri < <(match "[]" "socket://10.0.0.5:9100" "Q")
	[ "${driver}" = "foo2zjs:0/ppd/foo2zjs/HP-LaserJet_1020.ppd" ]
	[ "${uri}" = "socket://10.0.0.5:9100" ]
}

@test "match: no device ID over SNMP falls back to hrDeviceDescr as make and model" {
	snmp_answers "${DESCR} \"Canon MF4800 Series\""
	fake lpinfo <<'EOF2'
#!/bin/bash
echo "lpinfo $*" >> "${CALLS}"
[ "$1 $2" = "--make-and-model Canon MF4800 Series" ] || exit 1
echo "CNRCUPSMF4800ZK.ppd Canon MF4800 Series UFRII LT"
EOF2
	IFS="${SEP}" read -r driver uri < <(match "[]" "socket://10.0.0.5" "Q")
	[ "${driver}" = "CNRCUPSMF4800ZK.ppd" ]
	[ "${uri}" = "socket://10.0.0.5" ]
}

@test "match: IP printer with no PPD match but IPP on 631 prints driverless" {
	snmp_answers "${DESCR} \"Some Printer\""
	ipp_port open
	IFS="${SEP}" read -r driver uri < <(match "[]" "socket://10.0.0.5" "Q")
	[ "${driver}" = "everywhere" ]
	[ "${uri}" = "ipp://10.0.0.5/ipp/print" ]
	grep -q "/631" "${CALLS}"
}

@test "match: a PPD match wins over driverless for an IP printer" {
	snmp_answers "${PWG_ID} \"MFG:HP;MDL:X;\""
	ipp_port open
	fake lpinfo <<'EOF2'
#!/bin/bash
echo "hp:x.ppd HP X"
EOF2
	IFS="${SEP}" read -r driver uri < <(match "[]" "socket://10.0.0.5" "Q")
	[ "${driver}" = "hp:x.ppd" ]
	[ "${uri}" = "socket://10.0.0.5" ]
	! grep -q "^timeout" "${CALLS}"
}

@test "match: cups-filters' driverless listing is not taken as an IP printer's PPD" {
	snmp_answers "${PWG_ID} \"MFG:HP;MDL:X;\""
	fake lpinfo <<'EOF2'
#!/bin/bash
echo "driverless:ipp://HP%20X._ipp._tcp.local/ HP X, driverless"
EOF2
	ipp_port open
	IFS="${SEP}" read -r driver uri < <(match "[]" "socket://10.0.0.5" "Q")
	[ "${driver}" = "everywhere" ]
	[ "${uri}" = "ipp://10.0.0.5/ipp/print" ]
}

@test "match: a switched-off driverless IP printer uses its saved PPD" {
	mkdir -p "${DRIVERLESS_CACHE}"
	echo '*PPD-Adobe: "4.3"' > "${DRIVERLESS_CACHE}/Q.ppd"
	echo "ipp://10.0.0.5/ipp/print" > "${DRIVERLESS_CACHE}/Q.uri"
	IFS="${SEP}" read -r driver uri < <(match "[]" "socket://10.0.0.5" "Q")
	[ "${driver}" = "everywhere" ]
	[ "${uri}" = "ipp://10.0.0.5/ipp/print" ]
}

@test "match: an IP printer is never probed on its print port (CLAUDE.md: 9100)" {
	snmp_answers "${DESCR} \"Some Printer\""
	ipp_port open
	match "[]" "socket://10.0.0.5:9100" "Q" >/dev/null
	# The only connection is the IPP probe, to 631.
	[ "$(grep -c "^timeout" "${CALLS}")" -eq 1 ]
	grep "^timeout" "${CALLS}" | grep -q "/631"
	! grep "^timeout" "${CALLS}" | grep -q 9100
}

@test "match: a Bonjour printer is matched from discovery only, as before" {
	found='[{"device":"dnssd://A._pdl-datastream._tcp.local/","driver":"drv"}]'
	IFS="${SEP}" read -r driver uri < <(match "${found}" "dnssd://A._pdl-datastream._tcp.local/" "Q")
	[ "${driver}" = "drv" ]
	[ "${uri}" = "dnssd://A._pdl-datastream._tcp.local/" ]
	# Not found: still no driver, and no SNMP, lpinfo or IPP probe.
	IFS="${SEP}" read -r driver uri < <(match "[]" "dnssd://B._pdl-datastream._tcp.local/" "Q")
	[ -z "${driver}" ]
	[ ! -e "${CALLS}" ]
}

@test "match: a switched-off driverless printer uses its saved PPD" {
	mkdir -p "${DRIVERLESS_CACHE}"
	echo '*PPD-Adobe: "4.3"' > "${DRIVERLESS_CACHE}/Q.ppd"
	echo "dnssd://A._ipp._tcp.local/" > "${DRIVERLESS_CACHE}/Q.uri"
	IFS="${SEP}" read -r driver uri < <(match "[]" "dnssd://A._pdl-datastream._tcp.local/" "Q")
	[ "${driver}" = "everywhere" ]
	[ "${uri}" = "dnssd://A._ipp._tcp.local/" ]
}
