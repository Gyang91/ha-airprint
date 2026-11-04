#!/usr/bin/env bats
# Printer status from SNMP (monitor.sh).

load helpers

setup() {
	OID_UPTIME=.1.3.6.1.2.1.1.3.0
	OID_SUPPLY=.1.3.6.1.2.1.43.11.1.1.6.1.1
	OID_LEVEL=.1.3.6.1.2.1.43.11.1.1.9.1.1
	load_functions "${ADDON}/monitor.sh" snmp_value error_reasons host_of job_counts
	fake_bin
}

@test "snmp_value matches by OID, not by line (CLAUDE.md: SNMPv1 drops missing objects)" {
	out=$(printf '%s\n' "${OID_UPTIME} 12345" "${OID_SUPPLY} \"Black Toner\"" "${OID_LEVEL} 640")
	[ "$(snmp_value "${out}" "${OID_SUPPLY}")" = "Black Toner" ]
	[ "$(snmp_value "${out}" "${OID_LEVEL}")" = "640" ]
	[ -z "$(snmp_value "${out}" .1.2.3)" ]
}

@test "error_reasons decodes hrPrinterDetectedErrorState" {
	fake snmpget <<'EOF2'
#!/bin/bash
echo '"48 "'
EOF2
	# 0x48 = 0x40 out of paper + 0x08 door open
	run error_reasons 10.0.0.5
	[ "${lines[0]}" = "Out of paper" ]
	[ "${lines[1]}" = "Door open" ]
	[ "${#lines[@]}" -eq 2 ]
}

@test "error_reasons: no answer, no reasons" {
	fake snmpget <<'EOF2'
#!/bin/bash
exit 1
EOF2
	run error_reasons 10.0.0.5
	[ -z "${output}" ]
}

@test "host_of takes the address discovery resolved, or the socket:// IP" {
	found='[{"device":"dnssd://HP\\032Laser._pdl-datastream._tcp.local/","address":"192.168.1.50"}]'
	[ "$(host_of 'dnssd://HP\032Laser._pdl-datastream._tcp.local/' "${found}")" = "192.168.1.50" ]
	[ "$(host_of "socket://10.0.0.7:9100" "[]")" = "10.0.0.7" ]
	[ -z "$(host_of 'dnssd://Gone._pdl-datastream._tcp.local/' "${found}")" ]
}

@test "job_counts counts waiting jobs per queue" {
	fake lpstat <<'EOF2'
#!/bin/bash
echo "HP_Laser-12   root   1024   Tue 04 Nov 2026"
echo "HP_Laser-13   root   1024   Tue 04 Nov 2026"
echo "Office_2-3    root   1024   Tue 04 Nov 2026"
EOF2
	[ "$(job_counts | jq -c -S .)" = '{"HP_Laser":2,"Office_2":1}' ]
}
