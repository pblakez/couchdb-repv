#!/bin/bash
#
# tests/integration.sh - live end-to-end tests against two throwaway CouchDBs.
#
# THIS SUITE CREATES AND DELETES DATABASES. You supply the servers; they must be
# disposable. Nothing here is hardcoded to a host, and there is no default that
# points anywhere: the suite refuses to start until you have written both files.
#
#   .repv-test-servers.csv   aliases test0 (source) and test1 (target)
#   .repv-test-env           credentials for those two hosts, chmod 600
#
# Copy repv-test-servers.csv.example and repv-test-env.example to those names, or
# point CDB_TEST_SERVERS / CDB_TEST_ENV somewhere else. Both are gitignored.
#
# EVERY database this creates is prefixed zz_test_, on those two hosts only, so
# teardown is unambiguous. It refuses to touch any host not in that table.
#
# usage:
#   tests/integration.sh            run every test, then tear down
#   tests/integration.sh keep       run every test, leave the databases behind
#   tests/integration.sh teardown   just delete every zz_test_* database
#

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${_here}/.." && pwd)"

CDB_SYSLOG=false
export CDB_SYSLOG
# shellcheck source=couchdb-repv-common.sh
. "${REPO}/couchdb-repv-common.sh"

# ---------------------------------------------------------------------------
# the fleet under test - supplied by you, never defaulted to a live host
# ---------------------------------------------------------------------------
#
# The suite reads the same two file formats the tool itself reads, through the
# same parsers, so setting it up is the same exercise as setting up a real job -
# and a bug in servers_load or env_load fails here rather than being papered
# over by a fixture.

SRC_ALIAS="test0"
TARG_ALIAS="test1"
PREFIX="zz_test_"

TEST_SERVERS="${CDB_TEST_SERVERS:-${REPO}/.repv-test-servers.csv}"
TEST_ENV="${CDB_TEST_ENV:-${REPO}/.repv-test-env}"

if [ ! -f "${TEST_SERVERS}" ]; then
	echo "no test servers table at ${TEST_SERVERS}" >&2
	echo "cp repv-test-servers.csv.example ${TEST_SERVERS} and point '${SRC_ALIAS}' and" >&2
	echo "'${TARG_ALIAS}' at two CouchDB servers you are willing to lose, or set CDB_TEST_SERVERS" >&2
	exit 1
fi

# Credentials come from the gitignored env file, never from this script: no
# password belongs in a committed file, test server or not.
if [ ! -f "${TEST_ENV}" ]; then
	echo "no test credentials at ${TEST_ENV}" >&2
	echo "cp repv-test-env.example ${TEST_ENV}, chmod 600 it, and fill in one" >&2
	echo "<host>_USER / <host>_PASS pair per server in ${TEST_SERVERS}, or set CDB_TEST_ENV" >&2
	exit 1
fi

servers_load "${TEST_SERVERS}" || exit 1
env_load "${TEST_ENV}" >/dev/null || exit 1

for _a in "${SRC_ALIAS}" "${TARG_ALIAS}"; do
	if [ -z "${CDB_SERVER[${_a}]+isset}" ]; then
		echo "${TEST_SERVERS} defines no alias '${_a}'" >&2
		echo "the suite needs exactly these two: ${SRC_ALIAS} (source) and ${TARG_ALIAS} (target)" >&2
		exit 1
	fi
done

SRC_URL="${CDB_SERVER[${SRC_ALIAS}]}"
TARG_URL="${CDB_SERVER[${TARG_ALIAS}]}"

# The generated servers tables further down write these URLs back out verbatim,
# and several assertions match on the scheme, so the suite pins itself to plain
# http. That is not a limitation of the tool - it is a statement about what these
# two servers are: disposable, on a network you control, holding nothing.
for _u in "${SRC_URL}" "${TARG_URL}"; do
	case "${_u}" in
		http://*) ;;
		*) echo "the integration suite only drives http:// test servers; got ${_u}" >&2; exit 1 ;;
	esac
done

# host_of is what the tool logs and what several assertions below match on, so
# deriving the host the same way keeps the two from drifting.
SRC_HOST="$(host_of "${SRC_URL}")"
TARG_HOST="$(host_of "${TARG_URL}")"

if [ "${SRC_HOST}" = "${TARG_HOST}" ]; then
	echo "${SRC_ALIAS} and ${TARG_ALIAS} resolve to the same server (${SRC_HOST})" >&2
	echo "the suite replicates between them and needs two" >&2
	exit 1
fi

# resolve_server does the credential lookup - port-qualified key first, then the
# bare hostname - so the suite cannot drift from how the tool finds a password.
SRC="$(resolve_server "${SRC_ALIAS}")" || exit 1
TARG="$(resolve_server "${TARG_ALIAS}")" || exit 1

TEST_PASS="${CDB_SECRET[${SRC_HOST}_PASS]:-${CDB_SECRET[${SRC_HOST%%:*}_PASS]:-}}"
if [ -z "${TEST_PASS}" ]; then
	echo "${TEST_ENV} has no password for ${SRC_HOST%%:*}" >&2
	exit 1
fi

# The guard that makes teardown safe to run: these are the only two hosts this
# script will ever delete from.
assert_test_host () {
	case "$1" in
		"${SRC_HOST}"|"${TARG_HOST}") return 0 ;;
		*) echo "REFUSING to touch ${1}: not one of the two servers in ${TEST_SERVERS}" >&2; exit 1 ;;
	esac
}
assert_test_host "${SRC_HOST}"
assert_test_host "${TARG_HOST}"

MODE="${1:-full}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cdb-integration.XXXXXX")"
ENV_FILE="${TMP}/env"
LOG="${TMP}/run.log"

PASS=0
FAIL=0
ok () { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
no () { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
assert_eq () {
	if [ "$2" = "$3" ]; then ok "$1"; else
		no "$1"; printf '       expected: [%s]\n' "$2"; printf '       actual  : [%s]\n' "$3"
	fi
}
section () { printf '\n== %s ==\n' "$1"; }

# ---------------------------------------------------------------------------
# CouchDB helpers (independent of the code under test, on purpose - a test that
# uses the same helpers as the implementation cannot catch a broken helper)
# ---------------------------------------------------------------------------

cq () { curl -sS -m 30 "$@"; }

dbs_on ()   { cq "$1/_all_dbs" | tr ',' '\n' | tr -d '[]"' ; }
test_dbs () { dbs_on "$1" | grep "^${PREFIX}" | sort; }
db_exists () { [ "$(cq -o /dev/null -w '%{http_code}' "$1/$2")" = "200" ]; }
docs_in ()  { cq "$1/$2" | grep -o '"doc_count":[0-9]*' | cut -d: -f2; }
mk_db ()    { cq -o /dev/null -X PUT "$1/$2"; }
rm_db ()    { cq -o /dev/null -X DELETE "$1/$2"; }
put_doc ()  { cq -o /dev/null -X PUT "$1/$2/$3" -H 'Content-Type: application/json' -d "{\"n\":\"$3\"}"; }
doc_exists () { [ "$(cq -o /dev/null -w '%{http_code}' "$1/$2/$3")" = "200" ]; }
snaps_of () { dbs_on "$1" | grep -E "^$2_snap_[0-9]{8}-[0-9]{6}$" | sed "s/^$2_snap_//" | sort; }

teardown () {
	local svr n=0
	for svr in "${SRC}" "${TARG}"; do
		while IFS= read -r db; do
			[ -z "${db}" ] && continue
			case "${db}" in "${PREFIX}"*) ;; *) continue ;; esac   # belt and braces
			rm_db "${svr}" "${db}"
			n=$((n + 1))
		done < <(test_dbs "${svr}")
	done
	echo "teardown: removed ${n} ${PREFIX}* database(s)"
}

cleanup () { rm -rf "${TMP}"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# preconditions
# ---------------------------------------------------------------------------

for svr in "${SRC}" "${TARG}"; do
	if ! cq -o /dev/null -f "${svr}/" ; then
		echo "cannot reach $(host_of "${svr}") - is that test server up?" >&2
		exit 1
	fi
done

if [ "${MODE}" = "teardown" ]; then
	teardown
	exit 0
fi

echo "integration: ${SRC_HOST} -> ${TARG_HOST}, everything prefixed ${PREFIX}"
teardown

umask 077
cp "${TEST_ENV}" "${ENV_FILE}"
# Every alias resolves its credentials by hostname, including the deliberately
# unreachable one used in the failure-injection section below.
printf '127.0.0.1_USER=unused\n127.0.0.1_PASS=unused\n' >> "${ENV_FILE}"
chmod 600 "${ENV_FILE}"
umask 022

# write_inventory <file> <rows...>  - each row is "src|targ|rep|db|keep".
# Server columns are aliases from ${SERVERS}; there is no other form.
write_inventory () {
	local f="$1"; shift
	echo 'src-svr,targ-svr,rep-svr,db-name,keep' > "${f}"
	local row
	for row in "$@"; do
		printf '%s\n' "${row//|/,}" >> "${f}"
	done
}

# write_servers <file> <rows...>  - each row is "alias|url"
write_servers () {
	local f="$1"; shift
	echo 'alias,url' > "${f}"
	local row
	for row in "$@"; do
		printf '%s\n' "${row//|/,}" >> "${f}"
	done
}

# One servers table for the whole suite. Every inventory below names these two
# aliases; credentials come from the env file, keyed by hostname.
SERVERS="${TMP}/servers.csv"
write_servers "${SERVERS}" \
	"test0|http://${SRC_HOST}" \
	"test1|http://${TARG_HOST}"

INV="${TMP}/inventory.csv"
write_inventory "${INV}" \
	"test0|test1|test1|${PREFIX}alpha|7/5/12/7" \
	"test0|test1|test1|${PREFIX}beta|7/5/12/7"

# run_engine <args...> - captures combined output into $LOG, returns the exit code
run_engine () {
	local rc=0
	"${REPO}/couchdb-repv.sh" --inventory "${INV}" --servers "${SERVERS}" --env "${ENV_FILE}" --sleep 0 "$@" \
		> "${LOG}" 2>&1 || rc=$?
	return "${rc}"
}

# ---------------------------------------------------------------------------
section "seed"
# ---------------------------------------------------------------------------

mk_db "${SRC}" "${PREFIX}alpha"
mk_db "${SRC}" "${PREFIX}beta"
for i in 1 2 3 4 5; do put_doc "${SRC}" "${PREFIX}alpha" "doc${i}"; done
for i in 1 2 3;       do put_doc "${SRC}" "${PREFIX}beta"  "doc${i}"; done

assert_eq "source alpha seeded with 5 docs" "5" "$(docs_in "${SRC}" "${PREFIX}alpha")"
assert_eq "source beta seeded with 3 docs"  "3" "$(docs_in "${SRC}" "${PREFIX}beta")"
assert_eq "target starts with no test databases" "" "$(test_dbs "${TARG}")"

# ---------------------------------------------------------------------------
section "dry run changes nothing"
# ---------------------------------------------------------------------------

BEFORE="$(test_dbs "${TARG}")"
rc=0; run_engine --dry-run true || rc=$?
assert_eq "dry run exits 0" "0" "${rc}"
assert_eq "dry run created nothing on the target" "${BEFORE}" "$(test_dbs "${TARG}")"
assert_eq "dry run says it would replicate alpha" "yes" \
	"$(grep -q "DRY-RUN.*REPLICATE ${PREFIX}alpha" "${LOG}" && echo yes || echo no)"

# ---------------------------------------------------------------------------
section "first real run: target does not exist yet"
# ---------------------------------------------------------------------------

rc=0; run_engine || rc=$?
assert_eq "first run exits 0" "0" "${rc}"
assert_eq "target alpha created with 5 docs" "5" "$(docs_in "${TARG}" "${PREFIX}alpha")"
assert_eq "target beta created with 3 docs"  "3" "$(docs_in "${TARG}" "${PREFIX}beta")"
# Nothing existed to snapshot, so versioning must report the skip, not a failure.
assert_eq "versioning skipped both rows (no target db yet)" "yes" \
	"$(grep -q 'FIN: versioning 0 OK, 2 skipped' "${LOG}" && echo yes || echo no)"
assert_eq "no snapshot taken on the first run" "" "$(snaps_of "${TARG}" "${PREFIX}alpha")"

# ---------------------------------------------------------------------------
section "second run: snapshot appears"
# ---------------------------------------------------------------------------

sleep 1
rc=0; run_engine || rc=$?
assert_eq "second run exits 0" "0" "${rc}"
assert_eq "alpha now has exactly one snapshot" "1" "$(snaps_of "${TARG}" "${PREFIX}alpha" | wc -l)"
assert_eq "beta now has exactly one snapshot"  "1" "$(snaps_of "${TARG}" "${PREFIX}beta" | wc -l)"
assert_eq "the snapshot has the same doc_count as the database" \
	"5" "$(docs_in "${TARG}" "${PREFIX}alpha_snap_$(snaps_of "${TARG}" "${PREFIX}alpha")")"
assert_eq "second run deleted nothing" "yes" \
	"$(grep -q '1 kept, 0 deleted' "${LOG}" && echo yes || echo no)"

# ---------------------------------------------------------------------------
section "ordering: versioning runs BEFORE replication"
# ---------------------------------------------------------------------------
#
# This is the property the whole design rests on. Add a document at the source,
# then run once. The target must gain it; the snapshot taken during that same
# run must NOT have it, because it captured the target as it stood beforehand.

put_doc "${SRC}" "${PREFIX}alpha" "late_doc"
assert_eq "source alpha now has 6 docs" "6" "$(docs_in "${SRC}" "${PREFIX}alpha")"

sleep 1
rc=0; run_engine || rc=$?
assert_eq "third run exits 0" "0" "${rc}"

NEWEST_SNAP="${PREFIX}alpha_snap_$(snaps_of "${TARG}" "${PREFIX}alpha" | tail -n1)"
assert_eq "the target gained the new document" "yes" \
	"$(doc_exists "${TARG}" "${PREFIX}alpha" late_doc && echo yes || echo no)"
assert_eq "the snapshot taken in that same run does NOT have it" "no" \
	"$(doc_exists "${TARG}" "${NEWEST_SNAP}" late_doc && echo yes || echo no)"
assert_eq "so the snapshot holds the previous state: 5 docs" \
	"5" "$(docs_in "${TARG}" "${NEWEST_SNAP}")"

# ---------------------------------------------------------------------------
section "databases named by some other scheme are invisible to retention"
# ---------------------------------------------------------------------------
#
# Anything sitting beside the base database that is not <db>_snap_<stamp> must
# be untouchable. Rotating-suffix names are the realistic case - they look like
# backups, sort next to the real snapshots, and are exactly what a prune bug
# would eat first.

for other in "${PREFIX}alpha_day_3" "${PREFIX}alpha_week_34" "${PREFIX}alpha_month_08" "${PREFIX}alpha_2026"; do
	mk_db "${TARG}" "${other}"
done

SNAPS_BEFORE_RUN4="$(snaps_of "${TARG}" "${PREFIX}alpha")"
sleep 1
rc=0; run_engine || rc=$?
assert_eq "run with foreign-named databases present exits 0" "0" "${rc}"

# Several runs in one day must collapse to a single snapshot: keep-daily keeps
# the newest snapshot of each day, so yesterday's stays and this morning's
# earlier run does not. Worth asserting, because it is the behaviour that makes
# a mid-day re-run safe to do.
assert_eq "repeated runs on one day collapse to one snapshot" \
	"1" "$(snaps_of "${TARG}" "${PREFIX}alpha" | wc -l)"
assert_eq "and the survivor is the newest, not the earlier one" \
	"no" "$(printf '%s\n' "$(snaps_of "${TARG}" "${PREFIX}alpha")" | grep -qxF "${SNAPS_BEFORE_RUN4}" && echo yes || echo no)"
for other in "${PREFIX}alpha_day_3" "${PREFIX}alpha_week_34" "${PREFIX}alpha_month_08" "${PREFIX}alpha_2026"; do
	assert_eq "${other} survived the prune" "yes" \
		"$(db_exists "${TARG}" "${other}" && echo yes || echo no)"
done

# ---------------------------------------------------------------------------
section "retention at scale"
# ---------------------------------------------------------------------------
#
# Retention only reads names, so backdated EMPTY databases exercise the
# selection and the deletes for the price of a PUT each.

N_BACKDATED=200
PRE_SCALE_SNAPS="$(snaps_of "${TARG}" "${PREFIX}alpha" | wc -l)"
echo "  creating ${N_BACKDATED} backdated snapshot databases..."
BACKDATED="${TMP}/backdated"
: > "${BACKDATED}"
for (( i = 1; i <= N_BACKDATED; i++ )); do
	date -d "2026-08-20 -${i} days" '+%Y%m%d-030000' >> "${BACKDATED}"
done
while IFS= read -r stamp; do
	mk_db "${TARG}" "${PREFIX}alpha_snap_${stamp}"
done < "${BACKDATED}"

TOTAL_SNAPS="$(snaps_of "${TARG}" "${PREFIX}alpha" | wc -l)"
assert_eq "backdated snapshots are in place" \
	"$(( N_BACKDATED + PRE_SCALE_SNAPS ))" "${TOTAL_SNAPS}"

# The circuit breaker first: the default ceiling must stop a bulk delete.
rc=0
"${REPO}/couchdb-repv-version.sh" --rep-svr "${TARG}" --targ-svr "${TARG}" --db-name "${PREFIX}alpha" \
	--keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-yearly 7 > "${LOG}" 2>&1 || rc=$?
assert_eq "--max-delete refuses a bulk delete" "1" "${rc}"
assert_eq "--max-delete says why" "yes" \
	"$(grep -q 'refusing to delete .* --max-delete is 8' "${LOG}" && echo yes || echo no)"
assert_eq "--max-delete deleted nothing" \
	"$(( TOTAL_SNAPS + 1 ))" "$(snaps_of "${TARG}" "${PREFIX}alpha" | wc -l)"

# A run - dry or real - adds its OWN snapshot to the candidate set before
# selecting, so the prediction has to include one too. predict_deletes models
# that: existing stamps plus one taken now.
predict_deletes () {
	{ snaps_of "${TARG}" "$1"; date '+%Y%m%d-%H%M%S'; } \
		| retention_select 7 5 12 7 2>/dev/null | grep -c '^DELETE ' || true
}

# Dry run at a raised ceiling: it must plan the deletes without doing them.
BEFORE_SNAPS="$(snaps_of "${TARG}" "${PREFIX}alpha")"
EXPECTED_DELETE_N="$(predict_deletes "${PREFIX}alpha")"
rc=0
"${REPO}/couchdb-repv-version.sh" --rep-svr "${TARG}" --targ-svr "${TARG}" --db-name "${PREFIX}alpha" \
	--keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-yearly 7 \
	--max-delete 500 --dry-run true > "${LOG}" 2>&1 || rc=$?
assert_eq "dry run at a raised ceiling exits 0" "0" "${rc}"
assert_eq "dry run deleted nothing" "${BEFORE_SNAPS}" "$(snaps_of "${TARG}" "${PREFIX}alpha")"
assert_eq "dry run planned the right number of deletes" \
	"${EXPECTED_DELETE_N}" "$(grep -c 'DRY-RUN: DELETE ' "${LOG}" || true)"

# Now for real.
echo "  pruning ${EXPECTED_DELETE_N} snapshots..."
sleep 1
rc=0
"${REPO}/couchdb-repv-version.sh" --rep-svr "${TARG}" --targ-svr "${TARG}" --db-name "${PREFIX}alpha" \
	--keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-yearly 7 \
	--max-delete 500 > "${LOG}" 2>&1 || rc=$?
assert_eq "the real prune exits 0" "0" "${rc}"

SURVIVORS="$(snaps_of "${TARG}" "${PREFIX}alpha")"

# The invariant, checked exactly: given the state before the run and the one
# snapshot the run actually took, the surviving set must equal what the pure
# retention function predicts - no more, no fewer.
NEW_STAMP="$(comm -13 <(printf '%s\n' "${BEFORE_SNAPS}") <(printf '%s\n' "${SURVIVORS}"))"
assert_eq "the run took exactly one new snapshot" \
	"1" "$(printf '%s\n' "${NEW_STAMP}" | grep -c .)"

PREDICTED="$( { printf '%s\n' "${BEFORE_SNAPS}"; printf '%s\n' "${NEW_STAMP}"; } \
	| retention_select 7 5 12 7 2>/dev/null | awk '$1=="KEEP"{print $2}' | sort)"

assert_eq "survivors are exactly what retention predicted" \
	"${PREDICTED}" "${SURVIVORS}"
assert_eq "the predicted set is not trivially everything" \
	"yes" "$( [ "$(printf '%s\n' "${PREDICTED}" | grep -c .)" -lt "$(printf '%s\n' "${BEFORE_SNAPS}" | grep -c .)" ] && echo yes || echo no)"

assert_eq "the base database survived the prune" "yes" \
	"$(db_exists "${TARG}" "${PREFIX}alpha" && echo yes || echo no)"
assert_eq "the base database still has its 6 documents" \
	"6" "$(docs_in "${TARG}" "${PREFIX}alpha")"
assert_eq "beta's snapshots were untouched by alpha's prune" \
	"1" "$(snaps_of "${TARG}" "${PREFIX}beta" | wc -l)"

# A second identical prune must be a no-op apart from its own new snapshot.
SURV_N="$(printf '%s\n' "${SURVIVORS}" | wc -l)"
sleep 1
rc=0
"${REPO}/couchdb-repv-version.sh" --rep-svr "${TARG}" --targ-svr "${TARG}" --db-name "${PREFIX}alpha" \
	--keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-yearly 7 \
	--max-delete 500 > "${LOG}" 2>&1 || rc=$?
assert_eq "an immediate second prune exits 0" "0" "${rc}"
assert_eq "an immediate second prune is stable (same count)" \
	"${SURV_N}" "$(snaps_of "${TARG}" "${PREFIX}alpha" | wc -l)"

# ---------------------------------------------------------------------------
section "mirror-only rows (keep = none)"
# ---------------------------------------------------------------------------
#
# 'none' means mirror-only: replicate the database, never snapshot it. The point
# of these assertions is the negative one - versioning must not run at all, so
# nothing is created and, crucially, nothing existing is deleted.

mk_db "${SRC}" "${PREFIX}mirror"
put_doc "${SRC}" "${PREFIX}mirror" m1

INV_MIRROR="${TMP}/inv-mirror.csv"
write_inventory "${INV_MIRROR}" \
	"test0|test1|test1|${PREFIX}mirror|none"

rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_MIRROR}" --servers "${SERVERS}" --env "${ENV_FILE}" \
	--sleep 0 > "${LOG}" 2>&1 || rc=$?
assert_eq "a mirror-only row runs clean" "0" "${rc}"
assert_eq "the database was replicated" "1" "$(docs_in "${TARG}" "${PREFIX}mirror")"
assert_eq "no snapshot was taken" "0" "$(snaps_of "${TARG}" "${PREFIX}mirror" | wc -l)"
assert_eq "the log says the row was mirror-only" "yes" \
	"$(grep -q "MIRROR-ONLY ${PREFIX}mirror" "${LOG}" && echo yes || echo no)"
assert_eq "the summary counts it" "yes" \
	"$(grep -q 'FIN: 1 row(s) MIRROR-ONLY' "${LOG}" && echo yes || echo no)"

# Run again: still no snapshots, and the mirror keeps working.
put_doc "${SRC}" "${PREFIX}mirror" m2
sleep 1
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_MIRROR}" --servers "${SERVERS}" --env "${ENV_FILE}" \
	--sleep 0 > "${LOG}" 2>&1 || rc=$?
assert_eq "a second mirror-only run is clean" "0" "${rc}"
assert_eq "the new document reached the target" "yes" \
	"$(doc_exists "${TARG}" "${PREFIX}mirror" m2 && echo yes || echo no)"
assert_eq "still no snapshots after a second run" "0" \
	"$(snaps_of "${TARG}" "${PREFIX}mirror" | wc -l)"

# The one that matters: switching a versioned database to mirror-only must not
# delete the snapshots it already has. Versioning never runs, so nothing prunes.
mk_db "${TARG}" "${PREFIX}mirror_snap_20260101-020500"
mk_db "${TARG}" "${PREFIX}mirror_snap_20250101-020500"
sleep 1
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_MIRROR}" --servers "${SERVERS}" --env "${ENV_FILE}" \
	--sleep 0 > "${LOG}" 2>&1 || rc=$?
assert_eq "a mirror-only run with old snapshots present is clean" "0" "${rc}"
assert_eq "pre-existing snapshots are NOT pruned by a mirror-only row" \
	"20250101-020500 20260101-020500" \
	"$(snaps_of "${TARG}" "${PREFIX}mirror" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "and no DELETE was even attempted" "no" \
	"$(grep -q 'DELETE' "${LOG}" && echo yes || echo no)"

# A partial sentinel is not a rejected value, it is an unsayable one:
# 'none/5/12/7' is simply not four integers, so there is no half-mirror-only
# state to check for and no error explaining one.
INV_MIXED="${TMP}/inv-mixed.csv"
write_inventory "${INV_MIXED}" \
	"test0|test1|test1|${PREFIX}mirror|none/5/12/7"
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_MIXED}" --servers "${SERVERS}" --env "${ENV_FILE}" > "${LOG}" 2>&1 || rc=$?
assert_eq "a partial sentinel is rejected" "1" "${rc}"
assert_eq "and the message names the offending value" "yes" \
	"$(grep -q "daily must be a non-negative integer, got 'none'" "${LOG}" && echo yes || echo no)"

# 0,0,0,0 stays refused, and now points at the right answer.
INV_ZEROS="${TMP}/inv-zeros.csv"
write_inventory "${INV_ZEROS}" \
	"test0|test1|test1|${PREFIX}mirror|0/0/0/0"
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_ZEROS}" --servers "${SERVERS}" --env "${ENV_FILE}" > "${LOG}" 2>&1 || rc=$?
assert_eq "0/0/0/0 is still refused" "1" "${rc}"
assert_eq "and now points at 'none' instead" "yes" \
	"$(grep -q "write 'none'" "${LOG}" && echo yes || echo no)"

# Case-insensitive, since a CSV gets edited by hand.
INV_CASE="${TMP}/inv-case.csv"
write_inventory "${INV_CASE}" \
	"test0|test1|test1|${PREFIX}mirror|NONE"
sleep 1
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_CASE}" --servers "${SERVERS}" --env "${ENV_FILE}" \
	--sleep 0 > "${LOG}" 2>&1 || rc=$?
assert_eq "the sentinel is case-insensitive" "0" "${rc}"
assert_eq "and still takes no snapshot" "yes" \
	"$(grep -q "MIRROR-ONLY ${PREFIX}mirror" "${LOG}" && echo yes || echo no)"

# A mixed inventory - one mirror-only row and one versioned row - must do both.
INV_BOTH="${TMP}/inv-both.csv"
write_inventory "${INV_BOTH}" \
	"test0|test1|test1|${PREFIX}mirror|none" \
	"test0|test1|test1|${PREFIX}beta|7/5/12/7"
BETA_SNAP_BEFORE="$(snaps_of "${TARG}" "${PREFIX}beta" | tail -n1)"
sleep 1
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_BOTH}" --servers "${SERVERS}" --env "${ENV_FILE}" \
	--sleep 0 > "${LOG}" 2>&1 || rc=$?
assert_eq "a mixed inventory runs clean" "0" "${rc}"
assert_eq "the mirror-only row still has no snapshots" "2" \
	"$(snaps_of "${TARG}" "${PREFIX}mirror" | wc -l)"
assert_eq "the versioned row in the same file DID snapshot" "yes" \
	"$( [ "$(snaps_of "${TARG}" "${PREFIX}beta" | tail -n1)" \> "${BETA_SNAP_BEFORE}" ] && echo yes || echo no)"
assert_eq "the summary counts exactly one mirror-only row" "yes" \
	"$(grep -q 'FIN: 1 row(s) MIRROR-ONLY' "${LOG}" && echo yes || echo no)"

# ---------------------------------------------------------------------------
section "system databases are never touched"
# ---------------------------------------------------------------------------

assert_eq "_users still present on the target" "yes" \
	"$(db_exists "${TARG}" _users && echo yes || echo no)"
assert_eq "_replicator still present on the target" "yes" \
	"$(db_exists "${TARG}" _replicator && echo yes || echo no)"
assert_eq "_users still present on the source" "yes" \
	"$(db_exists "${SRC}" _users && echo yes || echo no)"

# ---------------------------------------------------------------------------
section "run lock"
# ---------------------------------------------------------------------------
#
# A nightly run that overruns its slot must not meet the next one head on.

LOCK="${TMP}/run.lock"
if command -v flock >/dev/null 2>&1; then
	# Hold the lock from another process for the duration of the check. Note we
	# wait for it rather than killing it: `flock -c` runs its command as a child
	# that inherits the lock fd, so killing flock alone would not release it.
	flock "${LOCK}" -c 'sleep 3' &
	HOLDER=$!
	sleep 0.5

	rc=0
	"${REPO}/couchdb-repv.sh" --inventory "${INV}" --servers "${SERVERS}" --env "${ENV_FILE}" \
		--sleep 0 --lock-file "${LOCK}" > "${LOG}" 2>&1 || rc=$?
	assert_eq "a second concurrent run refuses to start" "1" "${rc}"
	assert_eq "and says why" "yes" \
		"$(grep -q 'another run holds' "${LOG}" && echo yes || echo no)"
	assert_eq "it stopped before doing any work" "no" \
		"$(grep -q 'ROW ' "${LOG}" && echo yes || echo no)"

	wait "${HOLDER}" 2>/dev/null

	# with the lock free it must run normally
	sleep 1
	rc=0
	"${REPO}/couchdb-repv.sh" --inventory "${INV}" --servers "${SERVERS}" --env "${ENV_FILE}" \
		--sleep 0 --lock-file "${LOCK}" > "${LOG}" 2>&1 || rc=$?
	assert_eq "once the lock is free the run proceeds" "0" "${rc}"
else
	echo "  skip  flock not available"
fi

# ---------------------------------------------------------------------------
section "failure injection: bad credentials"
# ---------------------------------------------------------------------------

BAD_ENV="${TMP}/bad-env"
umask 077
sed 's/_PASS=.*/_PASS=wrong-password/' "${ENV_FILE}" > "${BAD_ENV}"
umask 022
chmod 600 "${BAD_ENV}"

BEFORE="$(test_dbs "${TARG}")"
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV}" --servers "${SERVERS}" --env "${BAD_ENV}" --sleep 0 > "${LOG}" 2>&1 || rc=$?
assert_eq "a run with wrong credentials fails" "1" "${rc}"
assert_eq "it fails in preflight, before touching anything" "yes" \
	"$(grep -q 'every row failed preflight - aborting before any change' "${LOG}" && echo yes || echo no)"
assert_eq "nothing on the target changed" "${BEFORE}" "$(test_dbs "${TARG}")"

# ---------------------------------------------------------------------------
section "failure injection: a missing source database"
# ---------------------------------------------------------------------------

INV_MISSING="${TMP}/inv-missing.csv"
write_inventory "${INV_MISSING}" \
	"test0|test1|test1|${PREFIX}nosuchdb|7/5/12/7" \
	"test0|test1|test1|${PREFIX}beta|7/5/12/7"

BETA_SNAP_BEFORE="$(snaps_of "${TARG}" "${PREFIX}beta" | tail -n1)"
sleep 1
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_MISSING}" --servers "${SERVERS}" --env "${ENV_FILE}" --sleep 0 > "${LOG}" 2>&1 || rc=$?
assert_eq "the run reports failure" "1" "${rc}"
assert_eq "the bad row is named in the summary" "yes" \
	"$(grep -q "FAIL.*${PREFIX}nosuchdb.*preflight" "${LOG}" && echo yes || echo no)"
assert_eq "the missing database was NOT created on the target" "no" \
	"$(db_exists "${TARG}" "${PREFIX}nosuchdb" && echo yes || echo no)"
# Same day, so the snapshot count stays at one; what proves the row ran is that
# the surviving stamp is a newer one.
assert_eq "the good row still ran (a newer snapshot replaced the old one)" \
	"yes" \
	"$( [ "$(snaps_of "${TARG}" "${PREFIX}beta" | tail -n1)" \> "${BETA_SNAP_BEFORE}" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
section "failure injection: versioning fails => replication is skipped"
# ---------------------------------------------------------------------------
#
# The most important failure path. rep-svr points at a port with nothing on it,
# so the snapshot replication cannot even be issued. The target must be left
# exactly as it was: no snapshot deleted, and crucially NOT overwritten from the
# source while its previous state is unpreserved.

# A dead rep-svr needs its own table: 'dead' must not appear in ${SERVERS},
# where it would change the alias list the unknown-alias errors are asserted on.
SERVERS_DEAD="${TMP}/servers-dead.csv"
write_servers "${SERVERS_DEAD}" \
	"test0|http://${SRC_HOST}" \
	"test1|http://${TARG_HOST}" \
	"dead|http://127.0.0.1:1"

INV_BADREP="${TMP}/inv-badrep.csv"
write_inventory "${INV_BADREP}" \
	"test0|test1|dead|${PREFIX}beta|7/5/12/7"

put_doc "${SRC}" "${PREFIX}beta" "must_not_arrive"
BETA_TARGET_DOCS="$(docs_in "${TARG}" "${PREFIX}beta")"
BETA_SNAPS_BEFORE="$(snaps_of "${TARG}" "${PREFIX}beta")"

sleep 1
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_BADREP}" --servers "${SERVERS_DEAD}" --env "${ENV_FILE}" \
	--sleep 0 --skip-preflight > "${LOG}" 2>&1 || rc=$?
assert_eq "the run reports failure" "1" "${rc}"
assert_eq "it says replication was skipped because versioning failed" "yes" \
	"$(grep -q 'SKIP replicate .* versioning failed' "${LOG}" && echo yes || echo no)"
assert_eq "the new source document did NOT reach the target" "no" \
	"$(doc_exists "${TARG}" "${PREFIX}beta" must_not_arrive && echo yes || echo no)"
assert_eq "the target doc_count is unchanged" \
	"${BETA_TARGET_DOCS}" "$(docs_in "${TARG}" "${PREFIX}beta")"
assert_eq "no snapshot was deleted" \
	"${BETA_SNAPS_BEFORE}" "$(snaps_of "${TARG}" "${PREFIX}beta")"

# ---------------------------------------------------------------------------
section "error messages carry the reason"
# ---------------------------------------------------------------------------
#
# Helpers that report a failure must not be called inside $( ): a subshell
# discards the http code and body they set, and the caller then logs a bare
# "http=:" that tells an operator nothing. These assert the reason survives.

rc=0
"${REPO}/couchdb-repv-replicate.sh" --rep-svr http://127.0.0.1:1 --src-svr http://127.0.0.1:1 \
	--targ-svr http://127.0.0.1:1 --db-name "${PREFIX}beta" > "${LOG}" 2>&1 || rc=$?
assert_eq "an unreachable server fails" "1" "${rc}"
assert_eq "and the message names the transport error" "yes" \
	"$(grep -qE 'curl rc=7.*(Connection refused|Failed to connect)' "${LOG}" && echo yes || echo no)"
assert_eq "no empty 'http=:' message is produced" "no" \
	"$(grep -qE 'http=:[[:space:]]*$' "${LOG}" && echo yes || echo no)"

rc=0
"${REPO}/couchdb-repv-version.sh" --rep-svr "${TARG}" \
	--targ-svr "http://admin:definitely-wrong@${TARG_HOST}" --db-name "${PREFIX}beta" \
	--keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-yearly 7 > "${LOG}" 2>&1 || rc=$?
assert_eq "a wrong password fails" "1" "${rc}"
assert_eq "and the message carries CouchDB's own reason" "yes" \
	"$(grep -q 'http=401.*Name or password is incorrect' "${LOG}" && echo yes || echo no)"
assert_eq "the wrong password is not echoed back" "absent" \
	"$(grep -q 'definitely-wrong' "${LOG}" && echo LEAKED || echo absent)"

# ---------------------------------------------------------------------------
section "malformed inventory"
# ---------------------------------------------------------------------------

INV_SHORT="${TMP}/inv-short.csv"
{
	echo 'src-svr,targ-svr,rep-svr,db-name,keep'
	# db-name omitted, so 4 fields not 5
	echo "test0,test1,test1,7/5/12/7"
} > "${INV_SHORT}"
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_SHORT}" --servers "${SERVERS}" --env "${ENV_FILE}" > "${LOG}" 2>&1 || rc=$?
assert_eq "a row with the wrong field count is rejected, not guessed at" "1" "${rc}"
assert_eq "and it says which line and why" "yes" \
	"$(grep -q 'has 4 fields, header has 5' "${LOG}" && echo yes || echo no)"

INV_NOCOL="${TMP}/inv-nocol.csv"
echo 'src-svr,targ-svr,db-name,keep' > "${INV_NOCOL}"
echo "test0,test1,${PREFIX}beta,7/5/12/7" >> "${INV_NOCOL}"
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_NOCOL}" --servers "${SERVERS}" --env "${ENV_FILE}" > "${LOG}" 2>&1 || rc=$?
assert_eq "a header missing rep-svr is a startup error" "2" "${rc}"
assert_eq "and it names the missing column" "yes" \
	"$(grep -q 'header is missing column(s): rep-svr' "${LOG}" && echo yes || echo no)"

# Retention split across four columns is not a second accepted format - it is a
# header without a 'keep' column, and is refused as one.
INV_QUAD="${TMP}/inv-quad.csv"
echo 'src-svr,targ-svr,rep-svr,db-name,keep-daily,keep-weekly,keep-monthly,keep-yearly' > "${INV_QUAD}"
echo "test0,test1,test1,${PREFIX}beta,7,5,12,7" >> "${INV_QUAD}"
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_QUAD}" --servers "${SERVERS}" --env "${ENV_FILE}" > "${LOG}" 2>&1 || rc=$?
assert_eq "a header with four keep columns is a startup error" "2" "${rc}"
assert_eq "and it asks for the 'keep' column it wanted" "yes" \
	"$(grep -q 'header is missing column(s): keep' "${LOG}" && echo yes || echo no)"

INV_ZERO="${TMP}/inv-zero.csv"
write_inventory "${INV_ZERO}" "test0|test1|test1|${PREFIX}beta|0/0/0/0"
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_ZERO}" --servers "${SERVERS}" --env "${ENV_FILE}" > "${LOG}" 2>&1 || rc=$?
assert_eq "an all-zero keep policy is refused" "1" "${rc}"

# A row that spells its servers out as URLs: the URL is not a URL, it is an
# alias nobody defined, and the error has to say so rather than leave a mystery.
INV_BADTOK="${TMP}/inv-badtok.csv"
write_inventory "${INV_BADTOK}" \
	'http://${nosuchhost_USER}:${nosuchhost_PASS}@'"${SRC_HOST}|test1|test1|${PREFIX}beta|7/5/12/7"
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_BADTOK}" --servers "${SERVERS}" --env "${ENV_FILE}" > "${LOG}" 2>&1 || rc=$?
assert_eq "a URL where an alias belongs stops the row" "1" "${rc}"
assert_eq "and it is reported as an unknown alias, listing the real ones" "yes" \
	"$(grep -q 'unknown server alias.*the servers file defines: test0 test1' "${LOG}" && echo yes || echo no)"

# ---------------------------------------------------------------------------
section "server aliases and the keep column"
# ---------------------------------------------------------------------------
#
# The alias table puts one hop between what the inventory says and which machine
# gets written to, so the thing under test here is that the hop lands on the
# right box - and that a mistake in it stops the run rather than quietly
# retargeting it.
#
# Every other section already runs through aliases; what is added here is the
# behaviour specific to the table itself - the mapping log line, and the ways a
# bad table has to stop a run rather than quietly retarget it.

ALIAS_DIR="${TMP}/aliased"
mkdir -p "${ALIAS_DIR}"

assert_eq "the servers table carries no credentials at all" "absent" \
	"$(grep -q '@' "${SERVERS}" && echo LEAKED || echo absent)"

mk_db "${SRC}" "${PREFIX}alias"
put_doc "${SRC}" "${PREFIX}alias" a1
put_doc "${SRC}" "${PREFIX}alias" a2

INV_ALIAS="${ALIAS_DIR}/inv.csv"
write_inventory "${INV_ALIAS}" "test0|test1|test1|${PREFIX}alias|7/5/12/7"

# --- --check: resolves everything, touches nothing -------------------------
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_ALIAS}" --servers "${SERVERS}" --env "${ENV_FILE}" \
	--check > "${LOG}" 2>&1 || rc=$?
assert_eq "--check on a good aliased inventory exits 0" "0" "${rc}"
assert_eq "it loaded the table it was pointed at" "yes" \
	"$(grep -q "loaded 2 server alias(es) from ${SERVERS}" "${LOG}" && echo yes || echo no)"
assert_eq "and logged what the aliases mean, in host:port" "yes" \
	"$(grep -q "servers: test0 -> ${SRC_HOST}, test1 -> ${TARG_HOST}" "${LOG}" && echo yes || echo no)"
assert_eq "it prints the row in alias notation" "yes" \
	"$(grep -qE "CHECK: +${PREFIX}alias +test0 +test1 +test1 +7/5/12/7" "${LOG}" && echo yes || echo no)"
assert_eq "it shows the resolved servers with credentials redacted" "yes" \
	"$(grep -qE "CHECK: +test1 +-> +http://\*\*\*:\*\*\*@${TARG_HOST}" "${LOG}" && echo yes || echo no)"
assert_eq "--check created nothing on the target" "no" \
	"$(db_exists "${TARG}" "${PREFIX}alias" && echo yes || echo no)"
assert_eq "--check took no run lock" "no" \
	"$(grep -q 'holding run lock' "${LOG}" && echo yes || echo no)"

# --- the real thing --------------------------------------------------------
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_ALIAS}" --servers "${SERVERS}" --env "${ENV_FILE}" \
	--sleep 0 > "${LOG}" 2>&1 || rc=$?
assert_eq "an aliased inventory runs clean" "0" "${rc}"
assert_eq "the alias resolved to the right box - the data is on the target" "2" \
	"$(docs_in "${TARG}" "${PREFIX}alias")"
assert_eq "the first run takes no snapshot: there was no target state to preserve" "0" \
	"$(snaps_of "${TARG}" "${PREFIX}alias" | wc -l)"
assert_eq "the row is logged by alias, not by address" "yes" \
	"$(grep -q "${PREFIX}alias test0 -> test1" "${LOG}" && echo yes || echo no)"
assert_eq "the summary TARGET column uses the alias too" "yes" \
	"$(grep -qE "FIN: +${PREFIX}alias +test1" "${LOG}" && echo yes || echo no)"
assert_eq "the password never reached the log" "absent" \
	"$(grep -q -- "${TEST_PASS}" "${LOG}" && echo LEAKED || echo absent)"

# Second run: now there IS a target state, so it gets preserved first.
put_doc "${SRC}" "${PREFIX}alias" a3
sleep 1
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_ALIAS}" --servers "${SERVERS}" --env "${ENV_FILE}" \
	--sleep 0 > "${LOG}" 2>&1 || rc=$?
assert_eq "a second aliased run is clean" "0" "${rc}"
assert_eq "and it snapshots the previous target state" "1" \
	"$(snaps_of "${TARG}" "${PREFIX}alias" | wc -l)"
assert_eq "the new document reached the target" "yes" \
	"$(doc_exists "${TARG}" "${PREFIX}alias" a3 && echo yes || echo no)"
assert_eq "the snapshot holds the state from BEFORE this run" "2" \
	"$(docs_in "${TARG}" "${PREFIX}alias_snap_$(snaps_of "${TARG}" "${PREFIX}alias" | tail -n1)")"

# --- keep: none, in the single column --------------------------------------
mk_db "${SRC}" "${PREFIX}aliasmirror"
put_doc "${SRC}" "${PREFIX}aliasmirror" m1
INV_ALIAS_NONE="${ALIAS_DIR}/inv-none.csv"
write_inventory "${INV_ALIAS_NONE}" "test0|test1|test1|${PREFIX}aliasmirror|none"
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_ALIAS_NONE}" --servers "${SERVERS}" --env "${ENV_FILE}" \
	--sleep 0 > "${LOG}" 2>&1 || rc=$?
assert_eq "keep 'none' in the single column runs clean" "0" "${rc}"
assert_eq "it mirrored the database" "1" "$(docs_in "${TARG}" "${PREFIX}aliasmirror")"
assert_eq "and took no snapshot" "0" \
	"$(snaps_of "${TARG}" "${PREFIX}aliasmirror" | wc -l)"
assert_eq "the log says mirror-only" "yes" \
	"$(grep -q "MIRROR-ONLY ${PREFIX}aliasmirror" "${LOG}" && echo yes || echo no)"

# --- mistakes in the hop stop the run --------------------------------------

INV_BADALIAS="${ALIAS_DIR}/inv-badalias.csv"
write_inventory "${INV_BADALIAS}" "test0|nosuch|test1|${PREFIX}alias|7/5/12/7"
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_BADALIAS}" --servers "${SERVERS}" --env "${ENV_FILE}" > "${LOG}" 2>&1 || rc=$?
assert_eq "an unknown alias stops the row" "1" "${rc}"
assert_eq "and the error lists the aliases that do exist" "yes" \
	"$(grep -q "unknown server alias 'nosuch' - the servers file defines: test0 test1" "${LOG}" && echo yes || echo no)"

rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_BADALIAS}" --servers "${SERVERS}" --env "${ENV_FILE}" \
	--check > "${LOG}" 2>&1 || rc=$?
assert_eq "--check reports a rejected row as a failure" "1" "${rc}"

# Same again with an aliased inventory: four keep columns is a header with no
# 'keep' column, and it says so.
INV_QUADHDR="${ALIAS_DIR}/inv-quadhdr.csv"
{
	echo 'src-svr,targ-svr,rep-svr,db-name,keep-daily,keep-weekly,keep-monthly,keep-yearly'
	echo "test0,test1,test1,${PREFIX}alias,7,5,12,7"
} > "${INV_QUADHDR}"
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_QUADHDR}" --servers "${SERVERS}" --env "${ENV_FILE}" > "${LOG}" 2>&1 || rc=$?
assert_eq "a four-keep-column header is a startup error" "2" "${rc}"
assert_eq "and it asks for 'keep'" "yes" \
	"$(grep -q "header is missing column(s): keep" "${LOG}" && echo yes || echo no)"

INV_ZEROSLASH="${ALIAS_DIR}/inv-zeroslash.csv"
write_inventory "${INV_ZEROSLASH}" "test0|test1|test1|${PREFIX}alias|0/0/0/0"
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_ZEROSLASH}" --servers "${SERVERS}" --env "${ENV_FILE}" > "${LOG}" 2>&1 || rc=$?
assert_eq "0/0/0/0 is refused in the single column too" "1" "${rc}"
assert_eq "and points at 'none'" "yes" \
	"$(grep -q "write 'none'" "${LOG}" && echo yes || echo no)"

# An alias whose host has no credentials: caught at parse time, before any
# network call, so a typo in the table never reaches an unintended machine.
SERVERS_NOCREDS="${ALIAS_DIR}/servers-nocreds.csv"
write_servers "${SERVERS_NOCREDS}" "ghost|http://192.168.66.99:5984"
INV_GHOST="${ALIAS_DIR}/inv-ghost.csv"
write_inventory "${INV_GHOST}" "ghost|ghost|ghost|${PREFIX}alias|7/5/12/7"
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_GHOST}" --servers "${SERVERS}" --env "${ENV_FILE}" \
	--servers "${SERVERS_NOCREDS}" > "${LOG}" 2>&1 || rc=$?
assert_eq "an alias with no credentials in the env file stops the row" "1" "${rc}"
assert_eq "and the error names the exact env keys to add" "yes" \
	"$(grep -q '192.168.66.99_USER and 192.168.66.99_PASS' "${LOG}" && echo yes || echo no)"

# A duplicate alias refuses the WHOLE table: the entries that did parse would
# still write to real machines.
SERVERS_DUP="${ALIAS_DIR}/servers-dup.csv"
write_servers "${SERVERS_DUP}" \
	"test0|http://${SRC_HOST}" \
	"test0|http://${TARG_HOST}"
rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_ALIAS}" --servers "${SERVERS}" --env "${ENV_FILE}" \
	--servers "${SERVERS_DUP}" > "${LOG}" 2>&1 || rc=$?
assert_eq "a duplicate alias refuses the run" "1" "${rc}"
assert_eq "and says which alias" "yes" \
	"$(grep -q "duplicate alias 'test0'" "${LOG}" && echo yes || echo no)"

rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_ALIAS}" --servers "${SERVERS}" --env "${ENV_FILE}" \
	--servers /nonexistent-servers.csv > "${LOG}" 2>&1 || rc=$?
assert_eq "a --servers path that does not exist is a usage error" "2" "${rc}"

rc=0
"${REPO}/couchdb-repv.sh" --inventory "${INV_ALIAS}" --env "${ENV_FILE}" > "${LOG}" 2>&1 || rc=$?
assert_eq "omitting --servers is a usage error" "2" "${rc}"
assert_eq "and it says which flag is missing" "yes" \
	"$(grep -q -- '--servers is required' "${LOG}" && echo yes || echo no)"

# ---------------------------------------------------------------------------
section "credentials never reach the log"
# ---------------------------------------------------------------------------
#
# The definitive check: run everything once more capturing all output, and grep
# it for the actual password.

sleep 1
run_engine >/dev/null 2>&1 || true
assert_eq "the password does not appear anywhere in the run output" "absent" \
	"$(grep -q -- "${TEST_PASS}" "${LOG}" && echo "LEAKED" || echo "absent")"
assert_eq "but the host does, so the log is still useful" "present" \
	"$(grep -q -- "${TARG_HOST}" "${LOG}" && echo "present" || echo "missing")"
# That host appears in exactly one place now - the `servers:` mapping line. Every
# other line names the alias, which is what makes them readable and would
# otherwise mean the log never says which machine was written to.
assert_eq "and it is the servers mapping line that carries it" "present" \
	"$(grep -q "servers: test0 -> ${SRC_HOST}, test1 -> ${TARG_HOST}" "${LOG}" && echo "present" || echo "missing")"
assert_eq "while the row lines name the alias" "present" \
	"$(grep -q "ROW .*test0 -> test1" "${LOG}" && echo "present" || echo "missing")"
# A successful run logs host:port and aliases rather than whole URLs, so the
# ***:***@ marker is not guaranteed to appear. The assertion that matters is the
# negative one: no user:pass@ pair of any kind survives into the output.
assert_eq "no unredacted user:pass@ appears anywhere in the output" "none" \
	"$(grep -qE '://[^/@[:space:]*]+:[^/@[:space:]*]+@' "${LOG}" && echo "FOUND" || echo "none")"

# ...and prove the redactor does fire on a path that logs a whole URL.
assert_eq "an error path that logs a URL redacts it" "present" \
	"$(printf '%s' "$(log_err "http://admin:${TEST_PASS}@${TARG_HOST}/x" 2>&1)" | grep -q -- '\*\*\*:\*\*\*@' && echo "present" || echo "missing")"

# ---------------------------------------------------------------------------
section "continuous mode (non-default)"
# ---------------------------------------------------------------------------
#
# --continuous false is the default and every test above exercises it. This
# covers the other branch. It runs LAST, on a database of its own, because a
# continuous job left running would keep syncing in the background and quietly
# invalidate any assertion made after it.

mk_db "${SRC}" "${PREFIX}cont"
put_doc "${SRC}" "${PREFIX}cont" doc1

rc=0
"${REPO}/couchdb-repv-replicate.sh" --rep-svr "${TARG}" --src-svr "${SRC}" --targ-svr "${TARG}" \
	--db-name "${PREFIX}cont" --continuous true > "${LOG}" 2>&1 || rc=$?
assert_eq "a continuous replication is accepted" "0" "${rc}"
assert_eq "it says plainly that accepted is not working" "yes" \
	"$(grep -q 'accepted is not working' "${LOG}" && echo yes || echo no)"
assert_eq "it verifies against the scheduler rather than trusting the 202" "yes" \
	"$(grep -q "present in _scheduler/jobs" "${LOG}" && echo yes || echo no)"

# The replication id must be logged: it is the only handle for cancelling a
# transient continuous job, and an operator who cannot find it is stuck.
REP_ID="$(sed -n 's/.*replication_id=\([^ ]*\).*/\1/p' "${LOG}" | head -n1)"
assert_eq "the replication id is logged" "yes" \
	"$( [ -n "${REP_ID}" ] && echo yes || echo no)"

cq -o /dev/null -X POST "${TARG}/_replicate" -H 'Content-Type: application/json' \
	-d "{\"replication_id\":\"${REP_ID}\",\"cancel\":true}"
sleep 1
assert_eq "cancelling by that id stops the job" "no" \
	"$(cq "${TARG}/_scheduler/jobs" | grep -q "${PREFIX}cont" && echo yes || echo no)"

# ---------------------------------------------------------------------------

if [ "${MODE}" != "keep" ]; then
	echo
	teardown
else
	echo
	echo "keeping ${PREFIX}* databases (mode: keep)"
fi

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
