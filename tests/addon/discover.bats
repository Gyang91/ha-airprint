#!/usr/bin/env bats
# Reading Bonjour adverts and matching drivers (discover.sh).

load helpers

setup() {
	load_functions "${ADDON}/discover.sh" txt_value model_of driverless uri_name lpinfo_model driver_for
	MATCHES="${BATS_TEST_TMPDIR}/matches"
	fake_bin
}

TXT='"txtvers=1" "usb_MFG=HP" "usb_MDL=LaserJet 1020" "ty=HP LaserJet 1020" "product=(HP LaserJet 1020)" "pdl=application/vnd.hp-PCL,image/urf" "URF=W8,SRGB24"'

@test "txt_value reads one key" {
	[ "$(txt_value "${TXT}" usb_MFG)" = "HP" ]
	[ "$(txt_value "${TXT}" usb_MDL)" = "LaserJet 1020" ]
	[ -z "$(txt_value "${TXT}" nothing)" ]
}

@test "model_of prefers usb_MDL, then ty, then product, then the name" {
	[ "$(model_of "${TXT}" svc)" = "LaserJet 1020" ]
	[ "$(model_of '"ty=Brother HL-L2350DW"' svc)" = "Brother HL-L2350DW" ]
	[ "$(model_of '"product=(Canon MF4800)"' svc)" = "Canon MF4800" ]
	[ "$(model_of '"txtvers=1"' "My Printer")" = "My Printer" ]
}

@test "driverless needs URF or a PWG raster pdl" {
	driverless '"URF=W8"'
	driverless '"pdl=application/pdf,image/pwg-raster"'
	! driverless '"pdl=application/vnd.hp-PCL"'
}

@test "uri_name decodes avahi escapes and URL-encodes (CLAUDE.md trap)" {
	[ "$(uri_name 'HP\032Laser\032MFP\032131\032\040x\041')" = "HP%20Laser%20MFP%20131%20(x)" ]
	# An emoji arrives as its UTF-8 bytes.
	[ "$(uri_name '\240\159\150\168\032Office')" = "%F0%9F%96%A8%20Office" ]
}

@test "a driver match is looked up once and then cached" {
	fake lpinfo <<'EOF2'
#!/bin/bash
echo call >> "${BATS_TEST_TMPDIR}/calls"
echo "foo2zjs:0/ppd/foo2zjs/HP-LaserJet_1020.ppd HP LaserJet 1020 Foomatic"
EOF2
	[ "$(driver_for "MFG:HP;MDL:LaserJet 1020;" "LaserJet 1020")" = "foo2zjs:0/ppd/foo2zjs/HP-LaserJet_1020.ppd" ]
	[ "$(driver_for "MFG:HP;MDL:LaserJet 1020;" "LaserJet 1020")" = "foo2zjs:0/ppd/foo2zjs/HP-LaserJet_1020.ppd" ]
	[ "$(wc -l < "${BATS_TEST_TMPDIR}/calls")" -eq 1 ]
}

@test "no match: falls back to make and model, and both answers are cached" {
	fake lpinfo <<'EOF2'
#!/bin/bash
echo "$1" >> "${BATS_TEST_TMPDIR}/calls"
if [ "$1" = "--device-id" ]; then echo "lpinfo: client-error-not-found" >&2; exit 1; fi
echo "gutenprint.5.3://bjc-x/expert Canon"
EOF2
	[ "$(driver_for "MFG:Canon;MDL:X;" "Canon X")" = "gutenprint.5.3://bjc-x/expert" ]
	[ "$(driver_for "MFG:Canon;MDL:X;" "Canon X")" = "gutenprint.5.3://bjc-x/expert" ]
	[ "$(wc -l < "${BATS_TEST_TMPDIR}/calls")" -eq 2 ]
}

@test "cupsd not answering: nothing is cached, asked again next time" {
	fake lpinfo <<'EOF2'
#!/bin/bash
echo call >> "${BATS_TEST_TMPDIR}/calls"
echo "lpinfo: Bad file descriptor" >&2; exit 1
EOF2
	[ -z "$(driver_for "MFG:HP;MDL:X;" "X")" ]
	[ -z "$(driver_for "MFG:HP;MDL:X;" "X")" ]
	[ "$(wc -l < "${BATS_TEST_TMPDIR}/calls")" -eq 4 ]
	[ -z "$(ls -A "${MATCHES}")" ]
}
