#!/bin/bash
#
# tests/test-summary.sh - unit tests for --summary-json: the JSON quoting, the
#                         per-row object, and a whole run that fails preflight.
#                         No CouchDB, no network beyond the loopback interface.
#
# The summary is a contract with whatever reads it, unlike the FIN: lines, so
# its shape is pinned here. The end-to-end case points every alias at a closed
# port on 127.0.0.1: the connection is refused at once, every row fails
# preflight, and the run takes the abort path - the one path where, before this
# option existed, a run ended with no per-row record at all.
#
# usage: tests/test-summary.sh
#

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${_here}/.." && pwd)"

CDB_SYSLOG=false
export CDB_SYSLOG
# shellcheck source=couchdb-repv-common.sh
. "${REPO}/couchdb-repv-common.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cdb-test-summary.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

PASS=0
FAIL=0
ok () { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
no () { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

assert_eq () {
	if [ "$2" = "$3" ]; then ok "$1"; else
		no "$1"; printf '       expected: [%s]\n' "$2"; printf '       actual  : [%s]\n' "$3"
	fi
}

assert_contains () {
	case "$3" in
		*"$2"*) ok "$1" ;;
		*) no "$1"; printf '       wanted  : [%s]\n' "$2"; printf '       in      : [%s]\n' "$3" ;;
	esac
}

assert_not_contains () {
	case "$3" in
		*"$2"*) no "$1"; printf '       found   : [%s]\n' "$2" ;;
		*) ok "$1" ;;
	esac
}

# is_json <file> - parsed by python3 when there is one; otherwise skipped, so
# the suite still needs nothing but bash.
is_json () {
	if command -v python3 >/dev/null 2>&1; then
		python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null
	else
		return 0
	fi
}

echo "== json_quote =="

assert_eq "plain text"            '"orders"'                 "$(json_quote orders)"
assert_eq "empty string"          '""'                       "$(json_quote '')"
assert_eq "quote and backslash"   '"a\"b\\c"'                "$(json_quote 'a"b\c')"
assert_eq "newline and tab"       '"one\ntwo\tthree"'        "$(json_quote $'one\ntwo\tthree')"
assert_eq "carriage return"       '"x\ry"'                   "$(json_quote $'x\ry')"
assert_eq "other control dropped" '"bell"'                   "$(json_quote $'be\all')"

echo "== json_uint_or_null =="

assert_eq "integer"               '10'   "$(json_uint_or_null 10)"
assert_eq "leading zero"          '7'    "$(json_uint_or_null 007)"
assert_eq "dash is null"          'null' "$(json_uint_or_null -)"
assert_eq "empty is null"         'null' "$(json_uint_or_null '')"
assert_eq "negative is null"      'null' "$(json_uint_or_null -3)"

echo "== summary_row_json =="

row="$(summary_row_json 12 orders bak1 cloud bak1 192.168.66.5:5984 203.0.113.10:5984 192.168.66.5:5984 \
	7/5/12/7 ok '' 6 0 4 'already current')"
assert_eq "versioned row, exact" \
	'{"line":12,"db":"orders","source":"bak1","target":"cloud","driver":"bak1","source_host":"192.168.66.5:5984","target_host":"203.0.113.10:5984","driver_host":"192.168.66.5:5984","keep":"7/5/12/7","mirror_only":false,"status":"ok","stage":"","versions":6,"docs_updated":0,"seconds":4,"note":"already current"}' \
	"${row}"

row="$(summary_row_json 14 orders_test cloud bak1 bak1 203.0.113.10:5984 192.168.66.5:5984 192.168.66.5:5984 \
	none failed preflight '' '' '' 'cloud unreachable (curl rc=7)')"
assert_contains "mirror-only flag"          '"keep":"none","mirror_only":true' "${row}"
assert_contains "failed at preflight"       '"status":"failed","stage":"preflight"' "${row}"
assert_contains "no numbers become null"    '"versions":null,"docs_updated":null,"seconds":null' "${row}"
printf '%s' "${row}" > "${TMP}/row.json"
if is_json "${TMP}/row.json"; then ok "row parses as JSON"; else no "row parses as JSON"; fi

echo "== a run where every row fails preflight =="

# A closed port on the loopback interface: refused immediately, nothing leaves
# this machine. Port 1 (tcpmux) is assigned but in practice never listening.
SERVERS="${TMP}/servers.csv"
cat > "${SERVERS}" <<'CSV'
alias,url
bak1,http://127.0.0.1:1
cloud,http://127.0.0.2:1
CSV
ENVF="${TMP}/env"
printf '%s\n' '127.0.0.1_USER=admin' '127.0.0.1_PASS=not-a-real-pw' \
	'127.0.0.2_USER=admin' '127.0.0.2_PASS=not-a-real-pw-either' > "${ENVF}"
chmod 600 "${ENVF}"
INV="${TMP}/inventory.csv"
cat > "${INV}" <<'CSV'
src-svr,targ-svr,rep-svr,db-name,keep
cloud,bak1,bak1,orders,7/5/12/7
cloud,bak1,bak1,orders_test,none
CSV

OUT="${TMP}/out/summary.json"
mkdir -p "${TMP}/out"
run_repv () {
	"${REPO}/couchdb-repv.sh" --inventory "${INV}" --servers "${SERVERS}" --env "${ENVF}" \
		--sleep 0 --timeout 3 --lock-file "" --log-tag cdb-test-summary "$@" >"${TMP}/run.log" 2>&1
}

rc=0; run_repv --summary-json "${OUT}" || rc=$?
assert_eq "run exits 1 (every row failed preflight)" 1 "${rc}"
if [ -f "${OUT}" ]; then ok "summary written on the abort path"; else no "summary written on the abort path"; fi
doc="$(cat "${OUT}" 2>/dev/null)"
if is_json "${OUT}"; then ok "summary parses as JSON"; else no "summary parses as JSON"; fi
assert_contains "format named"             '"format":"couchdb-repv-summary","format_version":1' "${doc}"
assert_contains "exit code and reason"     '"exit_code":1,"aborted":"every row failed preflight"' "${doc}"
assert_contains "counts"                   '"counts":{"rows":2,"processed":0,"failed":2,"mirror_only":1,"rejected":0}' "${doc}"
assert_contains "row 2 failed at preflight" '"line":2,"db":"orders","source":"cloud","target":"bak1","driver":"bak1"' "${doc}"
assert_contains "reason names both servers" '"note":"cloud unreachable (curl rc=7); bak1 unreachable (curl rc=7)"' "${doc}"
assert_contains "log tag recorded"         '"log_tag":"cdb-test-summary"' "${doc}"
assert_not_contains "no password in it"    'not-a-real-pw' "${doc}"
assert_not_contains "no URL in it"         'http://' "${doc}"
left="$(find "${TMP}/out" -name '*.tmp.*' | wc -l)"
assert_eq "no temporary file left behind" 0 "${left}"
assert_contains "the run says where it wrote" "summary written to ${OUT}" "$(cat "${TMP}/run.log")"

echo "== the option is reporting only =="

rc=0; run_repv --summary-json "${TMP}/no-such-dir/summary.json" || rc=$?
assert_eq "missing directory: same exit code as without the option" 1 "${rc}"
assert_contains "missing directory: warned" "does not exist - no summary will be written" "$(cat "${TMP}/run.log")"
if [ -e "${TMP}/no-such-dir" ]; then no "missing directory: not created"; else ok "missing directory: not created"; fi

rm -f "${OUT}"
rc=0; run_repv --summary-json "${OUT}" --check || rc=$?
if [ -e "${OUT}" ]; then no "--check writes no summary"; else ok "--check writes no summary"; fi

rc=0; run_repv || rc=$?
assert_eq "without the option nothing changes: exit 1" 1 "${rc}"
assert_not_contains "without the option: no summary line" "summary written" "$(cat "${TMP}/run.log")"

echo
echo "summary: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
