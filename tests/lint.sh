#!/bin/bash
#
# tests/lint.sh - shellcheck every script in the repo.
#
# Runs at --severity=warning: the info-level noise here is almost entirely
# SC2016 on the literal ${host_USER} tokens, which are meant to stay unexpanded.
# Anything at warning or above is a real finding.
#
# usage: tests/lint.sh
#

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${_here}/.." && pwd)"
cd "${REPO}" || exit 1

if ! command -v shellcheck >/dev/null 2>&1; then
	echo "shellcheck not installed - skipping lint"
	exit 0
fi

files=(couchdb-*.sh tests/*.sh tools/*.sh)

echo "shellcheck $(shellcheck --version | awk '/version:/{print $2}') over ${#files[@]} file(s)"

rc=0
shellcheck -x -s bash --severity=warning --source-path="${REPO}" "${files[@]}" || rc=$?

if [ "${rc}" -eq 0 ]; then
	echo "lint: clean"
else
	echo "lint: FAILED"
fi
exit "${rc}"
