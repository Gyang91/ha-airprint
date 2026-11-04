#!/usr/bin/env bats
# Downloading the drivers named in the printers' Driver file URL (drivers.sh).

load helpers

setup() {
	fake_bin
	export AIRPRINT_TEST_OPTIONS="${BATS_TEST_TMPDIR}/options.json"
	export AIRPRINT_TEST_DRIVERS="${BATS_TEST_TMPDIR}/drivers"
	export AIRPRINT_TEST_WORK="${BATS_TEST_TMPDIR}/work"
	fake curl <<'EOF2'
#!/bin/bash
echo "$*" >> "${BATS_TEST_TMPDIR}/curl"
while [ $# -gt 1 ]; do [ "$1" = "-o" ] && { echo data > "$2"; }; shift; done
EOF2
	# Nothing is installed in these tests.
	fake dpkg <<'EOF2'
#!/bin/bash
echo amd64
EOF2
	fake install <<'EOF2'
#!/bin/bash
echo "install $*" >> "${BATS_TEST_TMPDIR}/installed"
EOF2
}

options() {
	jq -n --args '{printers: [$ARGS.positional[] | {name: "P", driver: .}]}' "$@" > "${AIRPRINT_TEST_OPTIONS}"
}

@test "an https driver is downloaded, refusing a redirect to http" {
	options "https://cdn.example.com/canon_amd64.deb"
	run bash "${ADDON}/drivers.sh"
	[ "${status}" -eq 0 ]
	[ -f "${AIRPRINT_TEST_DRIVERS}/canon_amd64.deb" ]
	grep -q -- "--proto-redir =https" "${BATS_TEST_TMPDIR}/curl"
}

@test "a plain http driver still works, with a warning" {
	options "http://cdn.example.com/canon.ppd"
	run bash "${ADDON}/drivers.sh"
	[[ "${output}" == *"warning: canon.ppd is downloaded over plain http"* ]]
	[ -f "${AIRPRINT_TEST_DRIVERS}/canon.ppd" ]
	! grep -q -- "--proto-redir" "${BATS_TEST_TMPDIR}/curl"
}

@test "the file is named after the link's path, not its query" {
	options "https://cdn.example.com/dl/Canon.tar.gz?token=a/b#x"
	run bash "${ADDON}/drivers.sh"
	[ -f "${AIRPRINT_TEST_DRIVERS}/Canon.tar.gz" ]
}

@test "a link without a file name is skipped" {
	options "https://cdn.example.com/" "https://cdn.example.com/.downloaded"
	run bash "${ADDON}/drivers.sh"
	[[ "${output}" == *"ignoring driver link https://cdn.example.com/:"* ]]
	[[ "${output}" == *"ignoring driver link https://cdn.example.com/.downloaded:"* ]]
	[ ! -f "${BATS_TEST_TMPDIR}/curl" ]
	# .downloaded is the list of downloads, not overwritten.
	[ -f "${AIRPRINT_TEST_DRIVERS}/.downloaded" ]
}

@test "a driver no longer listed is removed" {
	options "https://cdn.example.com/old.ppd"
	bash "${ADDON}/drivers.sh"
	[ -f "${AIRPRINT_TEST_DRIVERS}/old.ppd" ]
	options "https://cdn.example.com/new.ppd"
	run bash "${ADDON}/drivers.sh"
	[ ! -f "${AIRPRINT_TEST_DRIVERS}/old.ppd" ]
	[ -f "${AIRPRINT_TEST_DRIVERS}/new.ppd" ]
}
