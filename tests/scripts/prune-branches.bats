#!/usr/bin/env bats
# Which branches scripts/prune-branches.sh deletes, against a fake gh.

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/prune-branches.sh"

setup() {
	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
	export FIXTURES="${BATS_TEST_TMPDIR}"
	# Pull requests: state, head branch, last commit.
	cat > "${FIXTURES}/prs" <<'ROWS'
MERGED	feature-done	aaa
CLOSED	abandoned-pr	bbb
OPEN	in-review	ccc
MERGED	reused	ddd
MERGED	release-please--x	eee
ROWS
	# Branches: name, tip, protected.
	cat > "${FIXTURES}/branches" <<'ROWS'
main	m00	true
feature-done	aaa	false
abandoned-pr	bbb	false
in-review	ccc	false
reused	fff	false
release-please--x	eee	false
leftover-merged	ggg	false
wip-no-pr	hhh	false
protected-old	iii	true
ROWS
	# Commits ahead of main, per tip without a pull request.
	printf 'ggg 0\nhhh 3\n' > "${FIXTURES}/ahead"

	cat > "${BATS_TEST_TMPDIR}/bin/gh" <<'FAKE'
#!/bin/bash
sep=$'\x1f'
case "$*" in
"api repos/o/r --jq .default_branch") echo main ;;
"pr list "*) tr '\t' "${sep}" < "${FIXTURES}/prs" ;;
"api --paginate repos/o/r/branches"*) tr '\t' "${sep}" < "${FIXTURES}/branches" ;;
"api repos/o/r/compare/main..."*)
	sha=${2##*...}
	awk -v s="${sha}" '$1 == s { print $2 }' "${FIXTURES}/ahead" ;;
"api -X DELETE "*) echo "${4#repos/o/r/git/refs/heads/}" >> "${FIXTURES}/deleted" ;;
*) echo "unexpected: gh $*" >&2; exit 1 ;;
esac
FAKE
	chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
}

deleted() {
	sort "${FIXTURES}/deleted" | tr '\n' ' '
}

@test "deletes finished pull requests' branches and leftovers already on main" {
	run bash "${SCRIPT}" o/r
	[ "${status}" -eq 0 ]
	[ "$(deleted)" = "abandoned-pr feature-done leftover-merged release-please--x " ]
}

@test "keeps main, protected branches, open pull requests and anything with new work" {
	run bash "${SCRIPT}" o/r
	[[ "${output}" == *"keep in-review: it has an open pull request"* ]]
	# Pushed to again after its pull request was merged.
	[[ "${output}" == *"keep reused: it has commits of its own"* ]]
	[[ "${output}" == *"keep wip-no-pr: it has commits of its own"* ]]
	! grep -qx -e main -e protected-old -e in-review -e reused -e wip-no-pr "${FIXTURES}/deleted"
}

@test "dry run deletes nothing" {
	run bash "${SCRIPT}" o/r --dry-run
	[ "${status}" -eq 0 ]
	[[ "${output}" == *"would delete feature-done: its pull request is merged or closed"* ]]
	[[ "${output}" == *"would delete leftover-merged: everything on it is already on main"* ]]
	[ ! -f "${FIXTURES}/deleted" ]
}
