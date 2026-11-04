# Shared by the add-on's shell tests. The scripts run their main code when
# executed, so tests load only the functions they need.

ADDON="${BATS_TEST_DIRNAME}/../../airprint"

# load_functions FILE NAME... -> defines those functions from the script.
load_functions() {
	local file=$1 name
	shift
	for name in "$@"; do
		eval "$(sed -n "/^${name}() {/,/^}/p" "${file}")"
		declare -F "${name}" >/dev/null || { echo "no function ${name} in ${file}" >&2; return 1; }
	done
}

# A directory of fake commands, first on PATH.
fake_bin() {
	FAKE="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "${FAKE}"
	PATH="${FAKE}:${PATH}"
}

fake() {
	local name=$1
	cat > "${FAKE}/${name}"
	chmod +x "${FAKE}/${name}"
}
