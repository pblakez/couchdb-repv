#!/bin/bash
#
# tests/run-all.sh - lint, unit tests, then the live integration suite.
#
# The unit tests need nothing but bash and GNU date, and reach no network.
#
# The integration suite needs two throwaway CouchDB servers that YOU supply, in
# .repv-test-servers.csv and .repv-test-env (see tests/integration.sh). It
# creates and deletes databases, all prefixed zz_test_.
#
# usage:
#   tests/run-all.sh          everything
#   tests/run-all.sh --unit   lint + unit tests only, no network, no config
#

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

rc=0
run () {
	printf '\n########## %s ##########\n' "$1"
	shift
	"$@" || rc=1
}

run "lint"            bash "${_here}/lint.sh"
run "unit: retention" bash "${_here}/test-retention.sh"
run "unit: env"       bash "${_here}/test-env.sh"
run "unit: inventory" bash "${_here}/test-inventory.sh"
run "unit: summary"   bash "${_here}/test-summary.sh"
run "unit: docs"      bash "${_here}/test-docs.sh"

if [ "${1:-}" != "--unit" ]; then
	run "integration"  bash "${_here}/integration.sh" "${@}"
fi

printf '\n##########\n'
if [ "${rc}" -eq 0 ]; then
	echo "ALL SUITES PASSED"
else
	echo "SOME SUITES FAILED"
fi
exit "${rc}"
