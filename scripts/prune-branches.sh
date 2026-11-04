#!/usr/bin/env bash
# Deletes the repository's branches that nothing needs any more. Run by the
# Prune branches workflow; needs gh with a token that may write contents.
#
#   scripts/prune-branches.sh OWNER/REPO [--dry-run]
#
# A branch is deleted when either:
# - its pull request was merged or closed and the branch has not moved since
#   (its tip is still that pull request's last commit), so it can be restored
#   from the pull request's page; or
# - it has no pull request and no commit that is not already on the default
#   branch, so deleting it loses nothing.
# Never deleted: the default branch, protected branches, and any branch with an
# open pull request.
set -euo pipefail

REPO=$1
DRY_RUN=${2:-}

DEFAULT=$(gh api "repos/${REPO}" --jq .default_branch)

declare -A OPEN=() FINISHED=()

# Pull requests from this repository (not forks): open heads, and the last
# commit of every merged or closed one, per branch.
while IFS=$'\x1f' read -r state branch sha; do
	[ -n "${branch}" ] || continue
	if [ "${state}" = "OPEN" ]; then
		OPEN["${branch}"]=1
	else
		FINISHED["${branch}"]="${FINISHED[${branch}]:-} ${sha}"
	fi
done < <(gh pr list --repo "${REPO}" --state all --limit 1000 \
	--json state,headRefName,headRefOid,isCrossRepository \
	--jq '.[] | select(.isCrossRepository | not) | [.state, .headRefName, .headRefOid] | join("\u001f")')

while IFS=$'\x1f' read -r branch sha protected; do
	[ -n "${branch}" ] || continue

	if [ "${branch}" = "${DEFAULT}" ] || [ "${protected}" = "true" ]; then
		continue
	fi

	if [ -n "${OPEN[${branch}]:-}" ]; then
		echo "keep ${branch}: it has an open pull request"
		continue
	fi

	why=""
	if [[ " ${FINISHED[${branch}]:-} " == *" ${sha} "* ]]; then
		why="its pull request is merged or closed"
	elif [ -z "${FINISHED[${branch}]:-}" ] &&
		[ "$(gh api "repos/${REPO}/compare/${DEFAULT}...${sha}" --jq .ahead_by)" = "0" ]; then
		why="everything on it is already on ${DEFAULT}"
	fi

	if [ -z "${why}" ]; then
		echo "keep ${branch}: it has commits of its own"
		continue
	fi

	if [ "${DRY_RUN}" = "--dry-run" ]; then
		echo "would delete ${branch}: ${why}"
	elif gh api -X DELETE "repos/${REPO}/git/refs/heads/${branch}" >/dev/null; then
		echo "deleted ${branch}: ${why}"
	else
		echo "::warning::could not delete ${branch}"
	fi
done < <(gh api --paginate "repos/${REPO}/branches?per_page=100" \
	--jq '.[] | [.name, .commit.sha, (.protected | tostring)] | join("\u001f")')
