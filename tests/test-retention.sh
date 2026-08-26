#!/bin/bash
#
# tests/test-retention.sh - unit tests for retention_select. No CouchDB, no network.
#
# retention_select is the only code in this system that decides to delete data,
# so it is written as a pure function precisely so it can be tested like this.
# Expected values below are restic `forget` semantics: walking newest -> oldest,
# a snapshot is kept when it OPENS a new day/week/month/year bucket and that
# bucket type has keeps remaining.
#
# usage: tests/test-retention.sh
#

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${_here}/.." && pwd)"

CDB_SYSLOG=false
export CDB_SYSLOG
# shellcheck source=couchdb-repv-common.sh
. "${REPO}/couchdb-repv-common.sh"

PASS=0
FAIL=0

ok () { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
no () { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

assert_eq () {
	# usage: assert_eq <name> <expected> <actual>
	if [ "$2" = "$3" ]; then
		ok "$1"
	else
		no "$1"
		printf '       expected: %s\n' "$2"
		printf '       actual  : %s\n' "$3"
	fi
}

# select <policy...> < stamps  -> only the KEEP stamps, oldest-first, space joined
keeps () {
	retention_select "$@" | awk '$1=="KEEP"{print $2}' | sort | tr '\n' ' ' | sed 's/ $//'
}
deletes () {
	retention_select "$@" | awk '$1=="DELETE"{print $2}' | sort | tr '\n' ' ' | sed 's/ $//'
}
count_keep ()   { retention_select "$@" | grep -c '^KEEP '   || true; }
count_delete () { retention_select "$@" | grep -c '^DELETE ' || true; }

# daily_series <n> <end-date> - n consecutive daily stamps ending on <end-date>
daily_series () {
	local n="$1" end="$2" i
	for (( i = n - 1; i >= 0; i-- )); do
		date -d "${end} -${i} days" '+%Y%m%d-020500'
	done
}

echo "== retention_select =="

# --- the trivial cases -----------------------------------------------------

assert_eq "empty input produces no output" \
	"" \
	"$(printf '' | retention_select 7 5 12 7)"

assert_eq "a single snapshot is kept" \
	"20260825-020500" \
	"$(printf '20260825-020500\n' | keeps 7 5 12 7)"

# The newest snapshot must survive any policy, including one that gives it no
# bucket to land in. With all counts 0 the caller refuses to run at all, so this
# tests the floor inside the function itself.
assert_eq "newest is kept even when every bucket is exhausted" \
	"20260825-020500" \
	"$(printf '20260825-020500\n' | keeps 0 0 0 0)"

# --- ordering --------------------------------------------------------------

assert_eq "input order does not matter" \
	"$(daily_series 10 2026-08-25 | keeps 3 2 1 1)" \
	"$(daily_series 10 2026-08-25 | sort | keeps 3 2 1 1)"

# --- the documented example ------------------------------------------------
#
# 2026-08-25 is a Tuesday (ISO 2026-W35); 2026-08-23 is the Sunday that closes
# 2026-W34. So with keep-weekly 2 the weeklies are the 25th and the 23rd.

# All 20 days fall inside August 2026, so keep-monthly 1 and keep-yearly 1 land
# on the 25th, which the dailies already keep. keep-weekly 2 takes the 25th
# (W35) and the 23rd (the Sunday closing W34) - also already dailies. So the
# survivors are exactly the three dailies.
assert_eq "20 dailies at 3/2/1/1 keeps exactly the restic set" \
	"20260823-020500 20260824-020500 20260825-020500" \
	"$(daily_series 20 2026-08-25 | keeps 3 2 1 1)"

# 2025-08-26 .. 2026-08-25 at 7/5/12/7:
#   7 dailies    08-25 .. 08-19
#   5 weeklies   08-25, 08-23 (both already dailies) + 08-16, 08-09, 08-02  -> +3
#  12 monthlies  2026-08 (already) + 07,06,05,04,03,02,01, 2025-12,11,10,09 -> +11
#   7 yearlies   only 2026 and 2025 exist, and both land on days already kept -> +0
# = 7 + 3 + 11 = 21
assert_eq "365 dailies at 7/5/12/7 keeps 21 (7 daily + 3 new weekly + 11 new monthly)" \
	"21" \
	"$(daily_series 365 2026-08-25 | count_keep 7 5 12 7)"

assert_eq "365 dailies at 7/5/12/7 deletes the other 344" \
	"344" \
	"$(daily_series 365 2026-08-25 | count_delete 7 5 12 7)"

# Three years exercises keep-yearly properly. Same 21 as above, plus the year
# ends 2024-12-31 and 2023-12-31 which no other bucket type reaches. = 23.
assert_eq "1096 dailies at 7/5/12/7 keeps 23 (the 21 above + 2 older year ends)" \
	"23" \
	"$(daily_series 1096 2026-08-25 | count_keep 7 5 12 7)"

# The audit trail matters as much as the count: every keep must say which bucket
# type saved it, so a surprising survivor can be explained from the log.
assert_eq "each keep records the bucket type(s) that saved it" \
	"20241231-020500 yearly" \
	"$(daily_series 1096 2026-08-25 | retention_select 7 5 12 7 | awk '$2=="20241231-020500"{print $2, $3}')"

assert_eq "nothing is lost: keeps + deletes == input" \
	"1096" \
	"$(( $(daily_series 1096 2026-08-25 | count_keep 7 5 12 7) + $(daily_series 1096 2026-08-25 | count_delete 7 5 12 7) ))"

# --- more snapshots than days ----------------------------------------------
#
# Two runs on the same day must consume ONE daily keep, not two: the newest of
# the day wins and the older one falls through to the other bucket types.

assert_eq "two snapshots on one day consume one daily slot" \
	"20260823-020500 20260824-020500 20260825-235959" \
	"$(printf '%s\n' 20260825-235959 20260825-020500 20260824-020500 20260823-020500 | keeps 3 0 0 0)"

assert_eq "the older snapshot of a doubled day is deleted at keep-daily 1" \
	"20260825-020500" \
	"$(printf '%s\n' 20260825-235959 20260825-020500 | deletes 1 0 0 0)"

# --- ISO week boundaries ---------------------------------------------------
#
# The trap: %V without %G. 2025-12-31 is in ISO week 2026-W01, and 2027-01-03 is
# in ISO week 2026-W53. Grouping by "%Y-%V" would put 2025-12-31 and a snapshot
# from 2025-01-02 (also W01) in the same bucket, quietly discarding a year.

assert_eq "2025-12-31 groups into ISO 2026-W01, not 2025-W01" \
	"2026-W01" \
	"$(date -d 2025-12-31 '+%G-W%V')"

assert_eq "2025-01-02 and 2025-12-31 are different weekly buckets" \
	"20250102-020500 20251231-020500" \
	"$(printf '%s\n' 20251231-020500 20250102-020500 | keeps 0 2 0 0)"

# 2027-01-03 (Sunday) closes ISO 2026-W53; 2027-01-04 (Monday) opens 2027-W01.
assert_eq "2027-01-03 and 2027-01-04 are different weekly buckets" \
	"20270103-020500 20270104-020500" \
	"$(printf '%s\n' 20270104-020500 20270103-020500 | keeps 0 2 0 0)"

assert_eq "2027-01-03 and 2027-01-04 are the SAME monthly bucket" \
	"20270104-020500" \
	"$(printf '%s\n' 20270104-020500 20270103-020500 | keeps 0 0 1 0)"

# --- leap day --------------------------------------------------------------

assert_eq "2028-02-29 parses and is kept" \
	"20280229-020500" \
	"$(printf '20280229-020500\n' | keeps 1 0 0 0)"

assert_eq "a series across 2028-02-29 keeps the right dailies" \
	"20280228-020500 20280229-020500 20280301-020500" \
	"$(printf '%s\n' 20280301-020500 20280229-020500 20280228-020500 20280227-020500 | keeps 3 0 0 0)"

# --- year boundary ---------------------------------------------------------

assert_eq "Dec 31 and Jan 1 are different yearly buckets" \
	"20251231-020500 20260101-020500" \
	"$(printf '%s\n' 20260101-020500 20251231-020500 | keeps 0 0 0 2)"

assert_eq "keep-yearly 1 keeps only the newest year" \
	"20260101-020500" \
	"$(printf '%s\n' 20260101-020500 20251231-020500 20250101-020500 | keeps 0 0 0 1)"

# --- gaps ------------------------------------------------------------------
#
# restic keeps the last N snapshots that OPEN a bucket, not the last N calendar
# days. A three-month gap must not consume the daily keeps.

assert_eq "gaps do not consume keeps: 3 dailies span 3 months" \
	"20260101-020500 20260401-020500 20260701-020500" \
	"$(printf '%s\n' 20260701-020500 20260401-020500 20260101-020500 | keeps 3 0 0 0)"

# --- a realistic backup history --------------------------------------------
#
# Nightly for 40 days, weekly for the 6 months before that. Under 7/5/12/7 the
# survivors must include today and the 12 most recent distinct months present.

REALISTIC="$(
	daily_series 40 2026-08-25
	for w in $(seq 1 26); do date -d "2026-07-16 -${w} weeks" '+%Y%m%d-020500'; done
)"

assert_eq "realistic history: every survivor is also in the input" \
	"" \
	"$(comm -23 <(printf '%s\n' "${REALISTIC}" | keeps 7 5 12 7 | tr ' ' '\n' | sort) \
	            <(printf '%s\n' "${REALISTIC}" | sort -u))"

assert_eq "realistic history: today survives" \
	"$(date -d 2026-08-25 '+%Y%m%d-020500')" \
	"$(printf '%s\n' "${REALISTIC}" | keeps 7 5 12 7 | tr ' ' '\n' | tail -n1)"

# --- policies that switch one bucket type off ------------------------------

assert_eq "keep-daily 0 still keeps weeklies" \
	"20260816-020500 20260823-020500 20260825-020500" \
	"$(daily_series 20 2026-08-25 | keeps 0 3 0 0)"

assert_eq "keep-monthly 3 over 100 days keeps 3 months plus the newest floor" \
	"3" \
	"$(daily_series 100 2026-08-25 | count_keep 0 0 3 0)"

# --- malformed input -------------------------------------------------------

assert_eq "a malformed stamp is rejected rather than silently mis-bucketed" \
	"1" \
	"$(printf '%s\n' 20260825-020500 not-a-stamp-x | retention_select 7 5 12 7 >/dev/null 2>&1; echo $?)"

assert_eq "blank lines in the input are ignored" \
	"20260825-020500" \
	"$(printf '\n20260825-020500\n\n' | keeps 1 0 0 0)"

echo
echo "== guards =="

assert_eq "is_snapshot_of accepts a well-formed snapshot" \
	"0" "$(is_snapshot_of acme_snap_20260825-020500 acme; echo $?)"
assert_eq "is_snapshot_of rejects the base database" \
	"1" "$(is_snapshot_of acme acme; echo $?)"
assert_eq "is_snapshot_of rejects a _day_N rotating name" \
	"1" "$(is_snapshot_of acme_day_3 acme; echo $?)"
assert_eq "is_snapshot_of rejects a _week_NN rotating name" \
	"1" "$(is_snapshot_of acme_week_34 acme; echo $?)"
assert_eq "is_snapshot_of rejects a _month_NN rotating name" \
	"1" "$(is_snapshot_of acme_month_08 acme; echo $?)"
assert_eq "is_snapshot_of rejects a _YYYY rotating name" \
	"1" "$(is_snapshot_of acme_2026 acme; echo $?)"
assert_eq "is_snapshot_of rejects a snapshot of a DIFFERENT database" \
	"1" "$(is_snapshot_of acme_other_snap_20260825-020500 acme; echo $?)"
assert_eq "is_snapshot_of rejects a truncated timestamp" \
	"1" "$(is_snapshot_of acme_snap_20260825 acme; echo $?)"
assert_eq "is_snapshot_of rejects a trailing suffix" \
	"1" "$(is_snapshot_of acme_snap_20260825-020500_x acme; echo $?)"
# CouchDB names may contain + ( ) $ - all regex metacharacters. The base name is
# quoted inside the =~ so they match literally rather than as a pattern.
assert_eq "is_snapshot_of treats regex metacharacters in the db name literally" \
	"0" "$(is_snapshot_of 'ga+orders(1)_snap_20260825-020500' 'ga+orders(1)'; echo $?)"
assert_eq "is_snapshot_of does not let . in the base match any character" \
	"1" "$(is_snapshot_of 'axme_snap_20260825-020500' 'a.me'; echo $?)"

assert_eq "never_delete protects _users"      "0" "$(never_delete _users; echo $?)"
assert_eq "never_delete protects _replicator" "0" "$(never_delete _replicator; echo $?)"
assert_eq "never_delete ignores a normal db"  "1" "$(never_delete acme_snap_20260825-020500; echo $?)"

assert_eq "valid_db_name accepts a normal name"     "0" "$(valid_db_name orders; echo $?)"
assert_eq "valid_db_name rejects a leading digit"   "1" "$(valid_db_name 9lives; echo $?)"
assert_eq "valid_db_name rejects upper case"        "1" "$(valid_db_name Acme; echo $?)"
assert_eq "valid_db_name rejects a leading _"       "1" "$(valid_db_name _users; echo $?)"
assert_eq "valid_db_name rejects an embedded space" "1" "$(valid_db_name 'a b'; echo $?)"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
