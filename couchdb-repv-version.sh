#!/bin/bash
#
# couchdb-repv-version.sh - restic-style snapshot + retention for ONE CouchDB database.
#
# script location /opt/couchdb-repv/couchdb-repv-version.sh
#
# Takes a point-in-time copy of <targ-svr>/<db-name> as
# <targ-svr>/<db-name>_snap_<YYYYMMDD-HHMMSS>, then deletes the snapshots that
# fall outside the keep policy - the same selection `restic forget` makes.
#
# Snapshots are target-to-target: the backup host copies from itself, so a
# snapshot costs nothing on the source and cannot be skewed by it. --rep-svr
# names the node whose /_replicate endpoint performs the copy.
#
# usage:
#   couchdb-repv-version.sh --rep-svr URL --targ-svr URL --db-name NAME \
#       --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-yearly 7 \
#       [--max-delete 8] [--timeout 60] [--dry-run true|false]
#
# exit codes:
#   0  snapshot taken (or dry-run planned) and retention applied
#   1  something failed - see the log
#   2  usage error
#   3  nothing to do: the target database does not exist yet. Deliberately
#      distinct so the caller can tell "no history to protect" apart from
#      "could not protect the history", and replicate anyway.
#

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=couchdb-repv-common.sh
. "${_here}/couchdb-repv-common.sh" || { echo "cannot source couchdb-repv-common.sh" >&2; exit 1; }

cdb_log_init "$(basename "$0")"

REP_SVR=""
TARG_SVR=""
DB_NAME=""
KEEP_DAILY=""
KEEP_WEEKLY=""
KEEP_MONTHLY=""
KEEP_YEARLY=""
MAX_DELETE=8
DRY_RUN="false"

usage () {
	cat >&2 <<-EOF
	usage: $(basename "$0") --rep-svr URL --targ-svr URL --db-name NAME \\
	           --keep-daily N --keep-weekly N --keep-monthly N --keep-yearly N \\
	           [--max-delete N] [--timeout SECONDS] [--dry-run true|false]

	  --rep-svr     CouchDB node that performs the copy (must reach --targ-svr)
	  --targ-svr    server holding the database to snapshot
	  --db-name     database to snapshot
	  --keep-*      restic-style retention counts; at least one must be > 0
	  --max-delete  refuse to delete more than N snapshots in one run (default ${MAX_DELETE})
	  --timeout     metadata request timeout, seconds (default 60)
	  --rep-timeout snapshot copy timeout, seconds (default 86400 - a big database
	                can hold the connection for hours)
	  --dry-run     plan everything, change nothing

	  eg: $(basename "$0") --rep-svr http://admin:pw@192.168.66.5:5984 \\
	          --targ-svr http://admin:pw@192.168.66.5:5984 --db-name app_meta \\
	          --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-yearly 7
	EOF
}

# --dry-run is specified as taking a value (--dry-run true) but is also accepted
# as a bare flag, because that is how everyone actually types it.
takes_value_or_bare_true () {
	local next="${1:-}"
	case "${next,,}" in
		true|false|yes|no|y|n|1|0|on|off) return 0 ;;
		*) return 1 ;;
	esac
}

while [ $# -gt 0 ]; do
	case "$1" in
		--rep-svr)      REP_SVR="${2:-}"; shift 2 ;;
		--targ-svr)     TARG_SVR="${2:-}"; shift 2 ;;
		--db-name)      DB_NAME="${2:-}"; shift 2 ;;
		--keep-daily)   KEEP_DAILY="${2:-}"; shift 2 ;;
		--keep-weekly)  KEEP_WEEKLY="${2:-}"; shift 2 ;;
		--keep-monthly) KEEP_MONTHLY="${2:-}"; shift 2 ;;
		--keep-yearly)  KEEP_YEARLY="${2:-}"; shift 2 ;;
		--max-delete)   MAX_DELETE="${2:-}"; shift 2 ;;
		--timeout)      CDB_TIMEOUT="${2:-}"; shift 2 ;;
		--rep-timeout)  CDB_REP_TIMEOUT="${2:-}"; shift 2 ;;
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

# ---------------------------------------------------------------------------
# validate
# ---------------------------------------------------------------------------

fail_usage () { log_err "$1"; usage; exit 2; }

[ -n "${REP_SVR}"  ] || fail_usage "--rep-svr is required"
[ -n "${TARG_SVR}" ] || fail_usage "--targ-svr is required"
[ -n "${DB_NAME}"  ] || fail_usage "--db-name is required"

for pair in "keep-daily:${KEEP_DAILY}" "keep-weekly:${KEEP_WEEKLY}" \
            "keep-monthly:${KEEP_MONTHLY}" "keep-yearly:${KEEP_YEARLY}"; do
	name="${pair%%:*}"; val="${pair#*:}"
	[ -n "${val}" ] || fail_usage "--${name} is required"
	if is_keep_none "${val}"; then
		# 'none' is an inventory-level sentinel meaning "mirror, never snapshot".
		# This script only ever snapshots, so there is nothing for it to do.
		fail_usage "--${name} is 'none', which means mirror-only. That is an inventory setting: a row whose keep is 'none' never invokes this script at all."
	fi
	is_uint "${val}" || fail_usage "--${name} must be a non-negative integer, got '${val}'"
done
is_uint "${MAX_DELETE}" || fail_usage "--max-delete must be a non-negative integer"
is_uint "${CDB_TIMEOUT}" || fail_usage "--timeout must be a non-negative integer"
is_uint "${CDB_REP_TIMEOUT}" || fail_usage "--rep-timeout must be a non-negative integer"

# An all-zero policy selects every snapshot for deletion. That is never what
# anybody meant, so refuse rather than obey.
if [ "${KEEP_DAILY}" -eq 0 ] && [ "${KEEP_WEEKLY}" -eq 0 ] && \
   [ "${KEEP_MONTHLY}" -eq 0 ] && [ "${KEEP_YEARLY}" -eq 0 ]; then
	fail_usage "refusing to run: all four --keep-* values are 0, which would select every snapshot for deletion"
fi

valid_db_name "${DB_NAME}" || fail_usage "not a valid CouchDB database name: '${DB_NAME}'"

REP_SVR="$(normalise_url "${REP_SVR}")"   || exit 2
TARG_SVR="$(normalise_url "${TARG_SVR}")" || exit 2

VER_T0="$(date +%s)"
SNAP_STAMP="$(date '+%Y%m%d-%H%M%S')"
SNAP_DB="$(snap_name "${DB_NAME}" "${SNAP_STAMP}")"

TARG_HOST="$(host_of "${TARG_SVR}")"

log "versioning ${DB_NAME} on ${TARG_HOST} (keep daily=${KEEP_DAILY} weekly=${KEEP_WEEKLY} monthly=${KEEP_MONTHLY} yearly=${KEEP_YEARLY}, max-delete=${MAX_DELETE}, dry-run=${DRY_RUN})"

# ---------------------------------------------------------------------------
# 1. list what is there
# ---------------------------------------------------------------------------

if ! couch_fetch_all_dbs "${TARG_SVR}"; then
	log_err "cannot list databases on ${TARG_HOST}: $(describe_last_error)"
	exit 1
fi
ALL_DBS="${CDB_ALL_DBS}"

BASE_PRESENT="false"
declare -a EXISTING_SNAPS=()
while IFS= read -r db; do
	[ -z "${db}" ] && continue
	if [ "${db}" = "${DB_NAME}" ]; then
		BASE_PRESENT="true"
	elif is_snapshot_of "${db}" "${DB_NAME}"; then
		EXISTING_SNAPS+=("${db#"${DB_NAME}${CDB_SNAP_SEP}"}")
	fi
done <<< "${ALL_DBS}"

if [ "${BASE_PRESENT}" != "true" ]; then
	# Nothing to protect yet. Exit 3 so the caller replicates instead of
	# treating this as a failure that should block the mirror.
	log "SKIP no target database ${DB_NAME} on ${TARG_HOST} yet - nothing to snapshot"
	cdb_result "ver_state=no-target-db" "ver_kept=0" "ver_created=" "ver_deleted=0" "ver_secs=$(( $(date +%s) - VER_T0 ))"
	exit 3
fi

log "found ${#EXISTING_SNAPS[@]} existing snapshot(s) of ${DB_NAME} on ${TARG_HOST}"

# ---------------------------------------------------------------------------
# 2. take the snapshot, and prove it
# ---------------------------------------------------------------------------
#
# The interlock that makes the delete step safe: pruning only happens after a
# snapshot has been created AND verified. No good new snapshot => no deletions.

if ! couch_fetch_doc_count "${TARG_SVR}" "${DB_NAME}"; then
	log_err "cannot read ${DB_NAME} on ${TARG_HOST}: $(describe_last_error)"
	exit 1
fi
BASE_DOCS="${CDB_DOC_COUNT}"

SNAP_OK="false"

if [ "${DRY_RUN}" = "true" ]; then
	log_dry "CREATE ${SNAP_DB} on ${TARG_HOST} from ${DB_NAME} (${BASE_DOCS} docs)"
	SNAP_OK="true"
else
	if couch_db_exists "${TARG_SVR}" "${SNAP_DB}"; then
		# Only reachable if the script is run twice inside one second.
		log_err "snapshot ${SNAP_DB} already exists on ${TARG_HOST} - refusing to overwrite"
		exit 1
	fi

	log "CREATE ${SNAP_DB} on ${TARG_HOST} from ${DB_NAME} (${BASE_DOCS} docs)"
	if couch_replicate "${REP_SVR}" "${TARG_SVR}/${DB_NAME}" "${TARG_SVR}/${SNAP_DB}" false true; then
		if couch_fetch_doc_count "${TARG_SVR}" "${SNAP_DB}"; then
			SNAP_DOCS="${CDB_DOC_COUNT}"
			if [ "${SNAP_DOCS}" = "${BASE_DOCS}" ]; then
				SNAP_OK="true"
				log "OK snapshot ${SNAP_DB} verified: doc_count=${SNAP_DOCS}, docs_read=${CDB_REP_DOCS_READ:-?} docs_written=${CDB_REP_DOCS_WRITTEN:-?}"
			else
				log_err "snapshot ${SNAP_DB} doc_count=${SNAP_DOCS} does not match ${DB_NAME} doc_count=${BASE_DOCS}"
			fi
		else
			log_err "snapshot ${SNAP_DB} created but could not be read back: $(describe_last_error)"
		fi
	else
		log_err "snapshot replication of ${DB_NAME} -> ${SNAP_DB} failed"
	fi

	if [ "${SNAP_OK}" != "true" ]; then
		log_err "SKIP retention for ${DB_NAME}: no verified new snapshot, so nothing will be deleted"
		exit 1
	fi
fi

# ---------------------------------------------------------------------------
# 3. select what to keep
# ---------------------------------------------------------------------------
#
# The new snapshot is included in the selection - in a dry run too, so the plan
# printed matches exactly what a real run would do.

declare -a CANDIDATES=("${SNAP_STAMP}")
if [ "${#EXISTING_SNAPS[@]}" -gt 0 ]; then
	CANDIDATES+=("${EXISTING_SNAPS[@]}")
fi

SELECTION=""
if ! SELECTION="$(printf '%s\n' "${CANDIDATES[@]}" | retention_select "${KEEP_DAILY}" "${KEEP_WEEKLY}" "${KEEP_MONTHLY}" "${KEEP_YEARLY}")"; then
	log_err "retention selection failed for ${DB_NAME} - nothing will be deleted"
	exit 1
fi

declare -a TO_DELETE=()
KEPT=0
while IFS= read -r line; do
	[ -z "${line}" ] && continue
	read -r verdict stamp reasons <<< "${line}"
	case "${verdict}" in
		KEEP)
			KEPT=$((KEPT + 1))
			# Named with its server, like the DELETE lines below: one
			# database versioned to several targets in a run otherwise
			# prints several indistinguishable blocks of KEEP lines.
			log "KEEP   $(snap_name "${DB_NAME}" "${stamp}") on ${TARG_HOST} (${reasons})"
			;;
		DELETE)
			TO_DELETE+=("${stamp}")
			;;
		*)
			log_err "retention produced an unrecognised line: ${line}"
			exit 1
			;;
	esac
done <<< "${SELECTION}"

log "retention: ${KEPT} kept, ${#TO_DELETE[@]} to delete (of ${#CANDIDATES[@]} snapshots)"

if [ "${#TO_DELETE[@]}" -eq 0 ]; then
	log "FIN: ${DB_NAME} on ${TARG_HOST}: snapshot ${SNAP_STAMP}, ${KEPT} kept, 0 deleted"
	cdb_result "ver_state=ok" "ver_kept=${KEPT}" "ver_created=${SNAP_STAMP}" "ver_deleted=0" "ver_secs=$(( $(date +%s) - VER_T0 ))"
	exit 0
fi

# ---------------------------------------------------------------------------
# 4. delete, through the guards
# ---------------------------------------------------------------------------
#
# Steady state is 0-2 deletions per nightly run. A much larger number means the
# clock, the policy or the snapshot list is wrong, so stop rather than obey.

if [ "${#TO_DELETE[@]}" -gt "${MAX_DELETE}" ]; then
	log_err "refusing to delete ${#TO_DELETE[@]} snapshots of ${DB_NAME} in one run: --max-delete is ${MAX_DELETE}"
	if [ "${DRY_RUN}" = "true" ]; then
		# In a dry run the whole point is to see the list, so print it even
		# though a real run would stop here.
		log_err "a real run would stop here; the ${#TO_DELETE[@]} snapshots it would have deleted are:"
		for stamp in "${TO_DELETE[@]}"; do
			log_err "  would delete $(snap_name "${DB_NAME}" "${stamp}") on ${TARG_HOST}"
		done
	fi
	log_err "review the list with --dry-run true, then raise --max-delete deliberately if it is correct"
	exit 1
fi

if [ "${KEPT}" -eq 0 ]; then
	# retention_select always keeps the newest, so this is unreachable; it is
	# here because "delete everything" must be impossible by construction.
	log_err "refusing to delete: retention selected 0 snapshots to keep"
	exit 1
fi

DELETED=0
DELETE_FAILED=0
for stamp in "${TO_DELETE[@]}"; do
	victim="$(snap_name "${DB_NAME}" "${stamp}")"

	# Every guard, re-checked immediately before the DELETE.
	if ! is_snapshot_of "${victim}" "${DB_NAME}"; then
		log_err "GUARD ${victim} is not a snapshot of ${DB_NAME} - skipped"
		DELETE_FAILED=$((DELETE_FAILED + 1)); continue
	fi
	if [ "${victim}" = "${DB_NAME}" ] || [ "${victim}" = "${SNAP_DB}" ]; then
		log_err "GUARD refusing to delete ${victim} (base database or the snapshot just taken)"
		DELETE_FAILED=$((DELETE_FAILED + 1)); continue
	fi
	if never_delete "${victim}"; then
		log_err "GUARD refusing to delete system database ${victim}"
		DELETE_FAILED=$((DELETE_FAILED + 1)); continue
	fi

	if [ "${DRY_RUN}" = "true" ]; then
		log_dry "DELETE ${victim} on ${TARG_HOST}"
		DELETED=$((DELETED + 1))
		continue
	fi

	if couch_req DELETE "${TARG_SVR}/${victim}"; then
		log "DELETE ${victim} on ${TARG_HOST}: http=${CDB_HTTP_CODE}"
		DELETED=$((DELETED + 1))
	else
		if [ "${CDB_CURL_RC}" -ne 0 ]; then
			log_err "DELETE ${victim} failed: curl rc=${CDB_CURL_RC}: ${CDB_BODY}"
		else
			log_err "DELETE ${victim} failed: http=${CDB_HTTP_CODE}: $(redact "${CDB_BODY}")"
		fi
		DELETE_FAILED=$((DELETE_FAILED + 1))
	fi
done

log "FIN: ${DB_NAME} on ${TARG_HOST}: snapshot ${SNAP_STAMP}, ${KEPT} kept, ${DELETED} deleted, ${DELETE_FAILED} delete(s) FAILED"

cdb_result "ver_state=ok" "ver_kept=${KEPT}" "ver_created=${SNAP_STAMP}" "ver_deleted=${DELETED}" \
	"ver_delete_failed=${DELETE_FAILED}" "ver_secs=$(( $(date +%s) - VER_T0 ))"

[ "${DELETE_FAILED}" -eq 0 ] || exit 1
exit 0
