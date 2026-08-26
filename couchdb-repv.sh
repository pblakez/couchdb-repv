#!/bin/bash
#
# couchdb-repv.sh - drive versioning + replication from an inventory CSV.
#
# script location /opt/couchdb-repv/couchdb-repv.sh
#
# Three files describe a run, and they are separate because they have three
# different audiences:
#
#   --inventory  what to replicate and how long to keep it. Names servers by a
#                short alias, so a row is a line you can read.
#   --servers    what each alias means. Holds NO credentials, so it is meant to
#                be committed: which box is bak1 stays answerable from git log.
#   --env        the passwords, 0600 and never committed.
#
# All three are required and none is inferred. This script is not tied to any
# particular fleet or job: run it once per job, with that job's three files and
# its own --log-tag.
#
# --check resolves all three and prints what they mean without touching
# anything, which is how an edit gets verified before 02:05 rather than after.
#
# For every row of the inventory, in order:
#
#   1. couchdb-repv-version.sh   - snapshot the target as it stands, prune old snapshots
#   2. couchdb-repv-replicate.sh - refresh the target from the source
#
# Versioning runs FIRST on purpose. The snapshot preserves the last known-good
# state before the mirror overwrites it, so a bad upstream day is recoverable.
# It follows that if versioning fails, replication for that row is SKIPPED:
# overwriting a target whose previous state could not be preserved is the one
# move that turns a bad day into data loss.
#
# usage:
#   couchdb-repv.sh --inventory FILE --servers FILE --env FILE [options]
#
# exit codes: 0 everything succeeded, 1 something failed, 2 usage error
#

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=couchdb-repv-common.sh
. "${_here}/couchdb-repv-common.sh" || { echo "cannot source couchdb-repv-common.sh" >&2; exit 1; }

VERSION_SH="${_here}/couchdb-repv-version.sh"
REPLICATE_SH="${_here}/couchdb-repv-replicate.sh"

INVENTORY=""
ENV_FILE=""
SERVERS_FILE=""
CHECK="false"
DRY_RUN="false"
SLEEP_FOR=1
MAX_DELETE=8
DBLIST_DIR=""
STRICT="false"
SKIP_PREFLIGHT="false"
ALLOW_INSECURE_ENV="false"
CONTINUOUS="false"
# The default lock is derived from the inventory below, NOT shared: both cron
# jobs fire at 5 2 * * *, so one lock for all of them would have each night's
# test-to-cloud run blocked by prod-to-bakup. Two different inventories are two
# different jobs; the same inventory twice over is the collision worth stopping.
LOCK_FILE=""
LOCK_FILE_SET="false"

cdb_log_init "$(basename "$0")"

usage () {
	cat >&2 <<-EOF
	usage: $(basename "$0") --inventory FILE --servers FILE --env FILE [options]

	  --inventory FILE       CSV describing what to replicate and how long to keep it
	  --servers FILE         CSV saying what each server alias means
	  --env FILE             .env-style file of <host>_USER= / <host>_PASS= entries
	  --check                resolve the config, print what it means, change
	                         nothing - no lock, no network, no writes
	  --log-tag TAG          syslog tag for the whole run (default: this script's
	                         name). Give each cron job its own, or they interleave
	  --dry-run true|false   plan everything, change nothing (default false)
	  --sleep SECONDS        pause between rows (default ${SLEEP_FOR})
	  --max-delete N         per-database snapshot delete ceiling (default ${MAX_DELETE})
	  --continuous true|false  replication mode (default false = one-shot)
	  --dblist-dir DIR       also record each source server's _all_dbs into DIR
	  --strict true|false    abort the whole run if any row fails preflight (default false)
	  --skip-preflight       go straight to work without checking servers first
	  --allow-insecure-env   permit a group/other-readable env file
	  --timeout SECONDS      metadata request timeout (default ${CDB_TIMEOUT})
	  --rep-timeout SECONDS  copy timeout (default ${CDB_REP_TIMEOUT}); a one-shot
	                         replication does not respond until it has finished
	  --lock-file PATH       run lock (default: one per inventory, in \${TMPDIR:-/tmp});
	                         pass an empty string to disable locking

	inventory format - the header row is authoritative, column order is free:

	  src-svr,targ-svr,rep-svr,db-name,keep
	  bak2,cloud,bak1,ledger_test,7/5/12/7
	  bak2,bak1,bak1,orders_test,none

	  Every server column is an ALIAS from the --servers table. An inventory
	  never holds a URL and never holds a credential: credentials come from
	  --env, looked up by the hostname the alias resolves to.

	  keep is 'none' - mirror-only: replicate the database but never snapshot it,
	  and so never prune it - or daily/weekly/monthly/yearly, eg 7/5/12/7.
	  0/0/0/0 is refused: use 'none' for that intent.

	  Blank lines and lines starting with # are ignored.

	servers format - what an alias means. No credentials, safe to commit:

	  alias,url
	  bak1,http://192.168.66.5:5984
	  cloud,http://203.0.113.10:5984

	examples:

	  $(basename "$0") \\
	      --inventory /root/couchdb-repv/repv-inventory.csv \\
	      --servers   /root/couchdb-repv/repv-servers.csv \\
	      --env       /root/couchdb-repv/.repv-env \\
	      --check

	  $(basename "$0") \\
	      --inventory /root/couchdb-repv/repv-inventory.csv \\
	      --servers   /root/couchdb-repv/repv-servers.csv \\
	      --env       /root/couchdb-repv/.repv-env \\
	      --dry-run
	EOF
}

takes_value_or_bare_true () {
	local next="${1:-}"
	case "${next,,}" in
		true|false|yes|no|y|n|1|0|on|off) return 0 ;;
		*) return 1 ;;
	esac
}

while [ $# -gt 0 ]; do
	case "$1" in
		--inventory)          INVENTORY="${2:-}"; shift 2 ;;
		--env)                ENV_FILE="${2:-}"; shift 2 ;;
		--servers)            SERVERS_FILE="${2:-}"; shift 2 ;;
		--sleep)              SLEEP_FOR="${2:-}"; shift 2 ;;
		--max-delete)         MAX_DELETE="${2:-}"; shift 2 ;;
		--dblist-dir)         DBLIST_DIR="${2:-}"; shift 2 ;;
		--timeout)            CDB_TIMEOUT="${2:-}"; shift 2 ;;
		--rep-timeout)        CDB_REP_TIMEOUT="${2:-}"; shift 2 ;;
		--lock-file)          LOCK_FILE="${2:-}"; LOCK_FILE_SET="true"; shift 2 ;;
		--continuous)         CONTINUOUS="$(parse_bool "${2:-}" --continuous)" || exit 2; shift 2 ;;
		--strict)             STRICT="$(parse_bool "${2:-}" --strict)" || exit 2; shift 2 ;;
		--check)              CHECK="true"; shift ;;
		--skip-preflight)     SKIP_PREFLIGHT="true"; shift ;;
		--allow-insecure-env) ALLOW_INSECURE_ENV="true"; shift ;;
		--log-tag)            CDB_LOG_TAG="${2:-}"; export CDB_LOG_TAG; shift 2 ;;
		--dry-run)
			if takes_value_or_bare_true "${2:-}"; then
				DRY_RUN="$(parse_bool "$2" --dry-run)" || exit 2
				shift 2
			else
				DRY_RUN="true"; shift
			fi
			;;
		-h|--help) usage; exit 0 ;;
		*) log_err "unknown argument: $1"; usage; exit 2 ;;
	esac
done

fail_usage () { log_err "$1"; usage; exit 2; }

[ -n "${INVENTORY}" ]   || fail_usage "--inventory is required"
[ -n "${SERVERS_FILE}" ] || fail_usage "--servers is required"
[ -n "${ENV_FILE}"  ]   || fail_usage "--env is required"
[ -f "${INVENTORY}" ] || fail_usage "inventory not found: ${INVENTORY}"
[ -r "${INVENTORY}" ] || fail_usage "inventory not readable: ${INVENTORY}"
[ -f "${SERVERS_FILE}" ] || fail_usage "servers file not found: ${SERVERS_FILE}"
[ -r "${SERVERS_FILE}" ] || fail_usage "servers file not readable: ${SERVERS_FILE}"
is_uint "${MAX_DELETE}"  || fail_usage "--max-delete must be a non-negative integer"
is_uint "${CDB_TIMEOUT}" || fail_usage "--timeout must be a non-negative integer"
is_uint "${CDB_REP_TIMEOUT}" || fail_usage "--rep-timeout must be a non-negative integer"
[[ "${SLEEP_FOR}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail_usage "--sleep must be a non-negative number"

if [ "${LOCK_FILE_SET}" != "true" ]; then
	_inv_key="$(basename "${INVENTORY}")"
	LOCK_FILE="${TMPDIR:-/tmp}/couchdb-repv-${_inv_key//[^A-Za-z0-9._-]/_}.lock"
fi

[ -x "${VERSION_SH}" ]   || fail_usage "not executable: ${VERSION_SH}"
[ -x "${REPLICATE_SH}" ] || fail_usage "not executable: ${REPLICATE_SH}"

# ---------------------------------------------------------------------------
# run lock
# ---------------------------------------------------------------------------
#
# A nightly run that outlives its 24h slot would otherwise meet the next one
# head on: two processes snapshotting and pruning the same databases at once.
# Fail fast instead of piling up - the missed run is visible in the cron mail.

if [ "${CHECK}" = "true" ]; then
	# --check writes nothing, so it must not queue behind - or block - a real
	# run. Being able to inspect the inventory while last night's job is still
	# going is most of the point.
	LOCK_FILE=""
fi

if [ -n "${LOCK_FILE}" ]; then
	if command -v flock >/dev/null 2>&1; then
		exec 9>"${LOCK_FILE}" || { log_err "cannot open lock file ${LOCK_FILE}"; exit 1; }
		if ! flock -n 9; then
			log_err "another run holds ${LOCK_FILE} - exiting rather than running two at once"
			exit 1
		fi
		log "holding run lock ${LOCK_FILE}"
	else
		log_warn "flock not available - running without a lock"
	fi
fi

# Where the children hand their numbers back (see cdb_result in the common
# library). Removed on every exit path, including the error ones.
RESULT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/couchdb-repv-results.XXXXXX")" || {
	log_err "cannot create a temporary directory for run results"
	exit 1
}
cleanup_results () { [ -n "${RESULT_DIR:-}" ] && rm -rf -- "${RESULT_DIR}"; }
trap cleanup_results EXIT

TS_START="$(date '+%Y-%m-%d %H:%M:%S')"
log "START inventory=${INVENTORY} servers=${SERVERS_FILE} env=${ENV_FILE} dry-run=${DRY_RUN} continuous=${CONTINUOUS} max-delete=${MAX_DELETE}"

env_load "${ENV_FILE}" "${ALLOW_INSECURE_ENV}" || exit 1

servers_load "${SERVERS_FILE}" || exit 1

# Every later line names servers by alias, which is what makes them readable -
# and would otherwise mean the log never says which machine was written to.
# Printing the mapping once keeps both: short lines, and an answer to "where is
# bak1?" without going and reading the servers file.
log "servers: $(servers_mapping)"

# ---------------------------------------------------------------------------
# parse the inventory
# ---------------------------------------------------------------------------
#
# The header row is parsed for column positions, so a missing or renamed column
# is a startup error rather than a silently shifted field. There are no quoted
# fields: CouchDB database names and these URLs cannot contain a comma, so a
# plain IFS=, split is exact - and every row's field count is checked against
# the header, which catches the mistake that split would hide.

REQUIRED_COLS=(src-svr targ-svr rep-svr db-name keep)
declare -A COL_IDX=()
HEADER_N=0

declare -a ROW_SRC=() ROW_TARG=() ROW_REP=() ROW_DB=()
declare -a ROW_KD=() ROW_KW=() ROW_KM=() ROW_KY=() ROW_LINE=() ROW_MIRROR_ONLY=()

PARSE_ERRORS=0
LINENO_CSV=0

while IFS= read -r raw || [ -n "${raw}" ]; do
	LINENO_CSV=$((LINENO_CSV + 1))
	raw="${raw%$'\r'}"
	trimmed="${raw#"${raw%%[![:space:]]*}"}"
	[ -z "${trimmed}" ] && continue
	[ "${trimmed:0:1}" = "#" ] && continue

	IFS=',' read -r -a fields <<< "${raw}"
	# trim each field
	for k in "${!fields[@]}"; do
		fields[k]="${fields[k]#"${fields[k]%%[![:space:]]*}"}"
		fields[k]="${fields[k]%"${fields[k]##*[![:space:]]}"}"
	done

	if [ "${HEADER_N}" -eq 0 ]; then
		HEADER_N="${#fields[@]}"
		for k in "${!fields[@]}"; do
			COL_IDX["${fields[k]}"]="${k}"
		done
		missing_cols=""
		for c in "${REQUIRED_COLS[@]}"; do
			[ -n "${COL_IDX[${c}]+isset}" ] || missing_cols+=" ${c}"
		done
		if [ -n "${missing_cols}" ]; then
			log_err "inventory ${INVENTORY} line ${LINENO_CSV}: header is missing column(s):${missing_cols}"
			log_err "expected header: $(IFS=,; echo "${REQUIRED_COLS[*]}")"
			exit 2
		fi
		log "inventory header OK (${HEADER_N} columns)"
		continue
	fi

	if [ "${#fields[@]}" -ne "${HEADER_N}" ]; then
		log_err "inventory line ${LINENO_CSV}: has ${#fields[@]} fields, header has ${HEADER_N} - skipped"
		PARSE_ERRORS=$((PARSE_ERRORS + 1))
		continue
	fi

	db="${fields[${COL_IDX[db-name]}]}"

	row_bad=0
	if ! valid_db_name "${db}"; then
		log_err "inventory line ${LINENO_CSV}: '${db}' is not a valid CouchDB database name"
		row_bad=1
	fi

	# One column, one shape. parse_keep owns the grammar; the row only has to
	# say which line it was on.
	kd=""; kw=""; km=""; ky=""; mirror_only=0
	if parse_keep "${fields[${COL_IDX[keep]}]}" "inventory line ${LINENO_CSV}: "; then
		if [ "${CDB_KEEP_NONE}" = "true" ]; then
			mirror_only=1
		else
			kd="${CDB_KEEP_D}"; kw="${CDB_KEEP_W}"
			km="${CDB_KEEP_M}"; ky="${CDB_KEEP_Y}"
		fi
	else
		row_bad=1
	fi

	# Aliases and credentials are resolved here, once, and never logged
	# afterwards. resolve_server's own error says what went wrong - unknown
	# alias, missing env key, bad URL - and this one says where to look.
	src=""; targ=""; rep=""
	for spec in "src:src-svr" "targ:targ-svr" "rep:rep-svr"; do
		var="${spec%%:*}"; col="${spec#*:}"
		val="$(resolve_server "${fields[${COL_IDX[${col}]}]}")" || {
			log_err "inventory line ${LINENO_CSV}: cannot resolve ${col} '${fields[${COL_IDX[${col}]}]}'"
			row_bad=1
			continue
		}
		printf -v "${var}" '%s' "${val}"
	done

	if [ "${row_bad}" -ne 0 ]; then
		PARSE_ERRORS=$((PARSE_ERRORS + 1))
		continue
	fi

	ROW_SRC+=("${src}");  ROW_TARG+=("${targ}"); ROW_REP+=("${rep}"); ROW_DB+=("${db}")
	ROW_KD+=("${kd}");    ROW_KW+=("${kw}");     ROW_KM+=("${km}");   ROW_KY+=("${ky}")
	ROW_LINE+=("${LINENO_CSV}"); ROW_MIRROR_ONLY+=("${mirror_only}")
done < "${INVENTORY}"

if [ "${HEADER_N}" -eq 0 ]; then
	log_err "inventory ${INVENTORY} has no header row"
	exit 2
fi

ROW_COUNT="${#ROW_DB[@]}"
if [ "${ROW_COUNT}" -eq 0 ]; then
	log_err "inventory ${INVENTORY} produced no usable rows (${PARSE_ERRORS} rejected)"
	exit 1
fi
log "inventory: ${ROW_COUNT} usable row(s), ${PARSE_ERRORS} rejected"

if [ "${PARSE_ERRORS}" -ne 0 ] && [ "${STRICT}" = "true" ]; then
	log_err "--strict true and ${PARSE_ERRORS} row(s) failed to parse - aborting before any change"
	exit 1
fi

# ---------------------------------------------------------------------------
# --check: say what this inventory means, then stop
# ---------------------------------------------------------------------------
#
# The alias table puts one hop between what the file says and which machine
# gets written to. This is where that hop is made visible: everything is
# resolved and printed, and nothing is touched - no lock, no network, no write.
# The point is that an edit can be checked at 17:00 rather than at 02:05.

if [ "${CHECK}" = "true" ]; then
	declare -A CHECK_URL=()
	declare -a C_DB=() C_S=() C_T=() C_R=() C_K=()
	w_db=8; w_lbl=6

	for (( r = 0; r < ROW_COUNT; r++ )); do
		C_DB+=("${ROW_DB[r]}")
		C_S+=("$(server_label "${ROW_SRC[r]}")")
		C_T+=("$(server_label "${ROW_TARG[r]}")")
		C_R+=("$(server_label "${ROW_REP[r]}")")
		if [ "${ROW_MIRROR_ONLY[r]}" -eq 1 ]; then
			C_K+=("none")
		else
			C_K+=("${ROW_KD[r]}/${ROW_KW[r]}/${ROW_KM[r]}/${ROW_KY[r]}")
		fi
		for u in "${ROW_SRC[r]}" "${ROW_TARG[r]}" "${ROW_REP[r]}"; do
			CHECK_URL["$(server_label "${u}")"]="$(redact "${u}")"
		done
	done

	[ "${#CHECK_URL[@]}" -eq 0 ] || for k in "${!CHECK_URL[@]}"; do
		[ "${#k}" -gt "${w_lbl}" ] && w_lbl="${#k}"
	done
	for (( i = 0; i < ROW_COUNT; i++ )); do
		[ "${#C_DB[i]}" -gt "${w_db}" ] && w_db="${#C_DB[i]}"
	done

	log "CHECK: inventory ${INVENTORY}"
	log "CHECK: servers   ${SERVERS_FILE}"
	# shellcheck disable=SC2059  # the format string is built, not user input
	log "$(printf "CHECK:   %-${w_db}s  %-${w_lbl}s  %-${w_lbl}s  %-${w_lbl}s  %s" \
		"DATABASE" "SRC" "TARG" "REP" "KEEP")"
	for (( i = 0; i < ROW_COUNT; i++ )); do
		# shellcheck disable=SC2059
		log "$(printf "CHECK:   %-${w_db}s  %-${w_lbl}s  %-${w_lbl}s  %-${w_lbl}s  %s" \
			"${C_DB[i]}" "${C_S[i]}" "${C_T[i]}" "${C_R[i]}" "${C_K[i]}")"
	done

	# The redacted URL is the useful half: http://***:***@host says credentials
	# were attached, http://host says none were.
	log "CHECK: servers as resolved"
	while IFS= read -r k; do
		[ -z "${k}" ] && continue
		# shellcheck disable=SC2059
		log "$(printf "CHECK:   %-${w_lbl}s  ->  %s" "${k}" "${CHECK_URL[${k}]}")"
	done < <([ "${#CHECK_URL[@]}" -eq 0 ] || printf '%s\n' "${!CHECK_URL[@]}" | sort)

	log "CHECK: ${ROW_COUNT} usable row(s), ${PARSE_ERRORS} rejected"
	if [ "${PARSE_ERRORS}" -ne 0 ]; then
		log_err "CHECK: ${PARSE_ERRORS} row(s) rejected - see the errors above"
		exit 1
	fi
	log "CHECK: inventory is usable - nothing was changed"
	exit 0
fi

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
#
# Finding a bad password before anything has run beats finding it on row 9 with
# half the fleet already touched. Every problem is reported, not just the first.

declare -a SKIP_ROW=()
PREFLIGHT_BAD=0

if [ "${SKIP_PREFLIGHT}" = "true" ]; then
	log_warn "--skip-preflight given: servers and source databases were not checked"
	for (( r = 0; r < ROW_COUNT; r++ )); do SKIP_ROW[r]=0; done
else
	log "preflight: checking servers and source databases"

	declare -A SERVER_OK=()
	check_server () {
		# Named by alias where the servers table knows one, so a preflight
		# failure reads as the name the inventory actually wrote.
		local url="$1" label
		label="$(server_label "${url}")"
		if [ -n "${SERVER_OK[${url}]+isset}" ]; then
			return "${SERVER_OK[${url}]}"
		fi
		if couch_req GET "${url}/_all_dbs"; then
			SERVER_OK["${url}"]=0
			log "preflight OK  ${label}"
			return 0
		fi
		SERVER_OK["${url}"]=1
		if [ "${CDB_CURL_RC}" -ne 0 ]; then
			log_err "preflight FAIL ${label}: curl rc=${CDB_CURL_RC}: ${CDB_BODY}"
		else
			log_err "preflight FAIL ${label}: http=${CDB_HTTP_CODE}: $(redact "${CDB_BODY}")"
		fi
		return 1
	}

	for (( r = 0; r < ROW_COUNT; r++ )); do
		SKIP_ROW[r]=0
		bad=0
		check_server "${ROW_SRC[r]}"  || bad=1
		check_server "${ROW_TARG[r]}" || bad=1
		check_server "${ROW_REP[r]}"  || bad=1

		if [ "${bad}" -eq 0 ]; then
			if ! couch_db_exists "${ROW_SRC[r]}" "${ROW_DB[r]}"; then
				log_err "preflight FAIL line ${ROW_LINE[r]}: source database ${ROW_DB[r]} not found on $(server_label "${ROW_SRC[r]}")"
				bad=1
			fi
		fi

		if [ "${bad}" -ne 0 ]; then
			SKIP_ROW[r]=1
			PREFLIGHT_BAD=$((PREFLIGHT_BAD + 1))
		fi
	done

	log "preflight: ${PREFLIGHT_BAD} of ${ROW_COUNT} row(s) unusable"

	if [ "${PREFLIGHT_BAD}" -eq "${ROW_COUNT}" ]; then
		log_err "every row failed preflight - aborting before any change"
		exit 1
	fi
	if [ "${PREFLIGHT_BAD}" -ne 0 ] && [ "${STRICT}" = "true" ]; then
		log_err "--strict true and ${PREFLIGHT_BAD} row(s) failed preflight - aborting before any change"
		exit 1
	fi
fi

# ---------------------------------------------------------------------------
# optional _all_dbs record
# ---------------------------------------------------------------------------

if [ -n "${DBLIST_DIR}" ]; then
	if [ ! -d "${DBLIST_DIR}" ]; then
		log_warn "--dblist-dir ${DBLIST_DIR} does not exist - no database list recorded"
	else
		declare -A DBLIST_DONE=()
		for (( r = 0; r < ROW_COUNT; r++ )); do
			[ -n "${DBLIST_DONE[${ROW_SRC[r]}]+isset}" ] && continue
			DBLIST_DONE["${ROW_SRC[r]}"]=1
			hostp="$(host_of "${ROW_SRC[r]}")"
			out="${DBLIST_DIR}/$(date -I)-${hostp//[^A-Za-z0-9._-]/_}-dbs.json"
			if [ "${DRY_RUN}" = "true" ]; then
				log_dry "RECORD _all_dbs of ${hostp} -> ${out}"
			elif couch_req GET "${ROW_SRC[r]}/_all_dbs" && printf '%s' "${CDB_BODY}" > "${out}"; then
				log "recorded _all_dbs of ${hostp} -> ${out}"
			else
				log_warn "could not record _all_dbs of ${hostp}"
			fi
		done
	fi
fi

# ---------------------------------------------------------------------------
# the work: version first, then replicate
# ---------------------------------------------------------------------------

ROWS_DONE=0
VER_OK=0
VER_SKIPPED_NEW=0
MIRROR_ONLY_ROWS=0
VER_FAILED=0
REP_OK=0
REP_SKIPPED=0
declare -a REP_FAILED=()

# Per-database summary, one entry per PROCESSED row. A database can legitimately
# appear more than once with different source/target pairs, so both aliases are
# carried too and the row - not the database name - is the key.
declare -a SUM_DB=() SUM_SRC=() SUM_TARG=() SUM_VERSIONS=() SUM_UPDATED=() SUM_SECS=() SUM_NOTE=()

# read_results <file> - parse a child's key=value lines into RES_* globals.
# Keys are whitelisted: this reads a file written by our own children, but
# assigning from unvalidated input is how a data file becomes code.
read_results () {
	local f="$1" k v
	# Cleared before every row: a key the child omits on one row would
	# otherwise keep the PREVIOUS row's value and be reported against the wrong
	# database - the kind of wrong number that gets believed.
	RES_ver_state=""; RES_ver_kept=""; RES_ver_deleted=""
	RES_rep_docs_updated=""; RES_rep_no_changes=""; RES_rep_dry_run=""
	[ -r "${f}" ] || return 0
	# Only the keys this summary consumes. The children emit more than this
	# (ver_created, rep_secs, rep_session, rep_docs_after) and log them; any key
	# not listed here is ignored rather than assigned, so a result file can
	# never introduce a variable this script did not ask for.
	while IFS='=' read -r k v; do
		case "${k}" in
			ver_state|ver_kept|ver_deleted|rep_docs_updated|rep_no_changes|rep_dry_run)
				printf -v "RES_${k}" '%s' "${v}" ;;
		esac
	done < "${f}"
}

# Children log to syslog themselves under CDB_LOG_TAG, so their stdout is
# relayed to the screen only - logging it again here would double every line.
export CDB_LOG_TAG
export CDB_TIMEOUT
export CDB_REP_TIMEOUT

run_child () {
	# usage: run_child <script> <args...>  - relays output, returns the exit code
	#
	# 9<&- closes the lock fd for the child: an inherited lock fd would keep the
	# run lock held by any process the child left behind.
	local rc=0
	"$@" 9<&- || rc=$?
	return "${rc}"
}

for (( r = 0; r < ROW_COUNT; r++ )); do
	db="${ROW_DB[r]}"
	line="${ROW_LINE[r]}"
	src_label="$(server_label "${ROW_SRC[r]}")"
	targ_label="$(server_label "${ROW_TARG[r]}")"

	if [ "${SKIP_ROW[r]}" -ne 0 ]; then
		log_warn "ROW ${line}: SKIP ${db} (${src_label} -> ${targ_label}) - failed preflight"
		REP_FAILED+=("line ${line}: ${db} ${src_label} -> ${targ_label} [preflight]")
		continue
	fi

	ROWS_DONE=$((ROWS_DONE + 1))
	log "ROW ${line}: ${db} ${src_label} -> ${targ_label}"

	ROW_T0="$(date +%s)"
	CDB_RESULT_FILE="${RESULT_DIR}/row-${r}.kv"
	export CDB_RESULT_FILE
	: > "${CDB_RESULT_FILE}"

	# ---- 1. versioning -----------------------------------------------------
	if [ "${ROW_MIRROR_ONLY[r]}" -eq 1 ]; then
		# A retention policy of 'none': mirror this database but never snapshot
		# it. Versioning is not run at all, so nothing is created and nothing
		# can be deleted - which also means the target is overwritten below
		# with NO prior state preserved. That is a deliberate choice per row,
		# and it is worth a line in the log every time.
		log "ROW ${line}: MIRROR-ONLY ${db} - keep is 'none', no snapshot taken and none pruned"
		MIRROR_ONLY_ROWS=$((MIRROR_ONLY_ROWS + 1))
		cdb_result "ver_state=mirror-only"
	else

		ver_rc=0
		run_child "${VERSION_SH}" \
			--rep-svr "${ROW_REP[r]}" \
			--targ-svr "${ROW_TARG[r]}" \
			--db-name "${db}" \
			--keep-daily "${ROW_KD[r]}" \
			--keep-weekly "${ROW_KW[r]}" \
			--keep-monthly "${ROW_KM[r]}" \
			--keep-yearly "${ROW_KY[r]}" \
			--max-delete "${MAX_DELETE}" \
			--dry-run "${DRY_RUN}" || ver_rc=$?

		case "${ver_rc}" in
			0)
				VER_OK=$((VER_OK + 1))
				;;
			3)
				# No target database yet: there is no history to protect, so
				# replicating is exactly what should happen next.
				VER_SKIPPED_NEW=$((VER_SKIPPED_NEW + 1))
				;;
			*)
				VER_FAILED=$((VER_FAILED + 1))
				REP_FAILED+=("line ${line}: ${db} versioning FAILED on ${targ_label} [rc ${ver_rc}]")
				REP_SKIPPED=$((REP_SKIPPED + 1))
				log_err "ROW ${line}: SKIP replicate ${db}: versioning failed, refusing to overwrite ${targ_label}/${db} with its previous state unpreserved"
				read_results "${CDB_RESULT_FILE}"
				SUM_DB+=("${db}"); SUM_SRC+=("${src_label}"); SUM_TARG+=("${targ_label}")
				SUM_VERSIONS+=("${RES_ver_kept:--}"); SUM_UPDATED+=("-")
				SUM_SECS+=("$(( $(date +%s) - ROW_T0 ))"); SUM_NOTE+=("VERSIONING FAILED, not replicated")
				sleep "${SLEEP_FOR}"
				continue
				;;
		esac

	fi

	# ---- 2. replication ----------------------------------------------------
	rep_rc=0
	run_child "${REPLICATE_SH}" \
		--rep-svr "${ROW_REP[r]}" \
		--src-svr "${ROW_SRC[r]}" \
		--targ-svr "${ROW_TARG[r]}" \
		--db-name "${db}" \
		--continuous "${CONTINUOUS}" \
		--dry-run "${DRY_RUN}" || rep_rc=$?

	if [ "${rep_rc}" -eq 0 ]; then
		REP_OK=$((REP_OK + 1))
	else
		REP_FAILED+=("line ${line}: ${db} ${src_label} -> ${targ_label} [replicate rc ${rep_rc}]")
	fi

	# ---- 3. record the row for the per-database summary ---------------------
	#
	# Timed here rather than after the sleep: --sleep is deliberate pacing
	# between rows, not work done on this database.
	ROW_SECS=$(( $(date +%s) - ROW_T0 ))
	read_results "${CDB_RESULT_FILE}"

	row_versions="${RES_ver_kept}"
	row_note=""
	case "${RES_ver_state}" in
		mirror-only)   row_versions="-"; row_note="mirror-only, no snapshots" ;;
		no-target-db)  row_versions="0"; row_note="first copy, nothing to snapshot yet" ;;
	esac
	[ -n "${row_versions}" ] || row_versions="-"

	if [ "${rep_rc}" -ne 0 ]; then
		row_updated="-"
		row_note="${row_note:+${row_note}; }REPLICATION FAILED"
	elif [ "${RES_rep_dry_run}" = "true" ]; then
		row_updated="-"
		row_note="${row_note:+${row_note}; }dry run"
	else
		row_updated="${RES_rep_docs_updated:--}"
		if [ "${RES_rep_no_changes}" = "true" ]; then
			row_note="${row_note:+${row_note}; }already current"
		fi
	fi
	if [ -n "${RES_ver_deleted}" ] && [ "${RES_ver_deleted}" != "0" ]; then
		row_note="${row_note:+${row_note}; }${RES_ver_deleted} snapshot(s) pruned"
	fi

	SUM_DB+=("${db}"); SUM_SRC+=("${src_label}"); SUM_TARG+=("${targ_label}")
	SUM_VERSIONS+=("${row_versions}"); SUM_UPDATED+=("${row_updated}")
	SUM_SECS+=("${ROW_SECS}"); SUM_NOTE+=("${row_note}")

	sleep "${SLEEP_FOR}"
done

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

TS_END="$(date '+%Y-%m-%d %H:%M:%S')"

# ---- per-database table ---------------------------------------------------
#
# One line per PROCESSED row, in inventory order. A database may appear twice
# with a different source or a different target, so those two columns are not
# decoration - they are what makes two rows for the same name tellable apart.
#
# DOCS UPD is the work THIS run did, derived in couch_replicate: 0 means the
# target was already current, not that the copy was skipped. It is deliberately
# not docs_read/docs_written, which are cumulative lifetime totals.
if [ "${#SUM_DB[@]}" -ne 0 ]; then
	w_db=8; w_src=6; w_targ=6
	for (( i = 0; i < ${#SUM_DB[@]}; i++ )); do
		[ "${#SUM_DB[i]}" -gt "${w_db}" ]     && w_db="${#SUM_DB[i]}"
		[ "${#SUM_SRC[i]}" -gt "${w_src}" ]   && w_src="${#SUM_SRC[i]}"
		[ "${#SUM_TARG[i]}" -gt "${w_targ}" ] && w_targ="${#SUM_TARG[i]}"
	done

	log "FIN: per-database summary"
	# shellcheck disable=SC2059  # the format string is built, not user input
	log "$(printf "FIN:   %-${w_db}s  %-${w_src}s  %-${w_targ}s  %8s  %9s  %6s" \
		"DATABASE" "SOURCE" "TARGET" "VERSIONS" "DOCS UPD" "TIME")"
	for (( i = 0; i < ${#SUM_DB[@]}; i++ )); do
		# shellcheck disable=SC2059
		line_out="$(printf "FIN:   %-${w_db}s  %-${w_src}s  %-${w_targ}s  %8s  %9s  %5ss" \
			"${SUM_DB[i]}" "${SUM_SRC[i]}" "${SUM_TARG[i]}" "${SUM_VERSIONS[i]}" "${SUM_UPDATED[i]}" "${SUM_SECS[i]}")"
		[ -n "${SUM_NOTE[i]}" ] && line_out="${line_out}   ${SUM_NOTE[i]}"
		log "${line_out}"
	done
fi

log "FIN: inventory ${INVENTORY}"
log "FIN: dry-run ${DRY_RUN}"
log "FIN: rows ${ROWS_DONE} processed of ${ROW_COUNT} usable (${PARSE_ERRORS} unparsable, ${PREFLIGHT_BAD} failed preflight)"
log "FIN: versioning ${VER_OK} OK, ${VER_SKIPPED_NEW} skipped (no target db yet), ${VER_FAILED} FAILED"
if [ "${MIRROR_ONLY_ROWS}" -ne 0 ]; then
	log "FIN: ${MIRROR_ONLY_ROWS} row(s) MIRROR-ONLY - replicated with no snapshot protection"
fi
if [ "${REP_SKIPPED}" -eq 0 ]; then
	log "FIN: replication ${REP_OK} OK, 0 skipped"
else
	log "FIN: replication ${REP_OK} OK, ${REP_SKIPPED} SKIPPED because versioning failed first"
fi
log "FIN:  TS_START ${TS_START}"
log "FIN:    TS_END ${TS_END}"
log "FIN: ${#REP_FAILED[@]} failure(s)"

if [ "${#REP_FAILED[@]}" -ne 0 ]; then
	for f in "${REP_FAILED[@]}"; do
		log_err "FIN:   FAIL ${f}"
	done
	exit 1
fi

exit 0
