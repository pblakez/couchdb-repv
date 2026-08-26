#!/bin/bash
#
# couchdb-repv-replicate.sh - copy ONE database from one CouchDB server to another.
#
# script location /opt/couchdb-repv/couchdb-repv-replicate.sh
#
# --rep-svr names the node whose /_replicate endpoint performs the copy; it must
# be able to reach BOTH --src-svr and --targ-svr. That is usually the target
# (it pulls), but not always: a LAN node replicating to a cloud node has to
# drive the copy itself, because the cloud node cannot reach a 192.168.x source.
#
# usage:
#   couchdb-repv-replicate.sh --rep-svr URL --src-svr URL --targ-svr URL --db-name NAME \
#       [--continuous true|false] [--create-target true|false] \
#       [--timeout 60] [--dry-run true|false]
#
# exit codes: 0 ok, 1 failed, 2 usage error
#

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=couchdb-repv-common.sh
. "${_here}/couchdb-repv-common.sh" || { echo "cannot source couchdb-repv-common.sh" >&2; exit 1; }

cdb_log_init "$(basename "$0")"

REP_SVR=""
SRC_SVR=""
TARG_SVR=""
DB_NAME=""
CONTINUOUS="false"
CREATE_TARGET="true"
DRY_RUN="false"

usage () {
	cat >&2 <<-EOF
	usage: $(basename "$0") --rep-svr URL --src-svr URL --targ-svr URL --db-name NAME \\
	           [--continuous true|false] [--create-target true|false] \\
	           [--timeout SECONDS] [--dry-run true|false]

	  --rep-svr     CouchDB node that performs the replication (must reach src AND targ)
	  --src-svr     source server URL
	  --targ-svr    target server URL
	  --db-name     database to copy (same name both ends)
	  --continuous  default false: one-shot, so http 200 means genuinely finished
	  --timeout     metadata request timeout, seconds (default 60)
	  --rep-timeout copy timeout, seconds (default 86400 - a one-shot replication
	                does not respond until it has finished)
	  --dry-run     plan everything, change nothing

	  eg: $(basename "$0") --rep-svr http://admin:pw@192.168.66.5:5984 \\
	          --src-svr http://admin:pw@203.0.113.10:5984 \\
	          --targ-svr http://admin:pw@192.168.66.5:5984 --db-name app_meta
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
		--rep-svr)       REP_SVR="${2:-}"; shift 2 ;;
		--src-svr)       SRC_SVR="${2:-}"; shift 2 ;;
		--targ-svr)      TARG_SVR="${2:-}"; shift 2 ;;
		--db-name)       DB_NAME="${2:-}"; shift 2 ;;
		--continuous)    CONTINUOUS="$(parse_bool "${2:-}" --continuous)" || exit 2; shift 2 ;;
		--create-target) CREATE_TARGET="$(parse_bool "${2:-}" --create-target)" || exit 2; shift 2 ;;
		--timeout)       CDB_TIMEOUT="${2:-}"; shift 2 ;;
		--rep-timeout)   CDB_REP_TIMEOUT="${2:-}"; shift 2 ;;
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

[ -n "${REP_SVR}"  ] || fail_usage "--rep-svr is required"
[ -n "${SRC_SVR}"  ] || fail_usage "--src-svr is required"
[ -n "${TARG_SVR}" ] || fail_usage "--targ-svr is required"
[ -n "${DB_NAME}"  ] || fail_usage "--db-name is required"
is_uint "${CDB_TIMEOUT}" || fail_usage "--timeout must be a non-negative integer"
is_uint "${CDB_REP_TIMEOUT}" || fail_usage "--rep-timeout must be a non-negative integer"
valid_db_name "${DB_NAME}" || fail_usage "not a valid CouchDB database name: '${DB_NAME}'"

REP_SVR="$(normalise_url "${REP_SVR}")"   || exit 2
SRC_SVR="$(normalise_url "${SRC_SVR}")"   || exit 2
TARG_SVR="$(normalise_url "${TARG_SVR}")" || exit 2

SRC_HOST="$(host_of "${SRC_SVR}")"
TARG_HOST="$(host_of "${TARG_SVR}")"
REP_HOST="$(host_of "${REP_SVR}")"

log "replicate ${DB_NAME}: ${SRC_HOST} -> ${TARG_HOST} (driven by ${REP_HOST}, continuous=${CONTINUOUS}, dry-run=${DRY_RUN})"

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
#
# CouchDB reports a missing source as 500 {"error":"db_not_found"} from deep
# inside the replicator. Checking here turns that into a sentence someone can
# act on.

if ! couch_fetch_doc_count "${SRC_SVR}" "${DB_NAME}"; then
	log_err "source database ${DB_NAME} unreadable on ${SRC_HOST}: $(describe_last_error)"
	exit 1
fi
SRC_DOCS="${CDB_DOC_COUNT}"

TARG_DOCS_BEFORE="absent"
if couch_db_exists "${TARG_SVR}" "${DB_NAME}"; then
	couch_fetch_doc_count "${TARG_SVR}" "${DB_NAME}"
	TARG_DOCS_BEFORE="${CDB_DOC_COUNT:-?}"
elif [ "${CREATE_TARGET}" != "true" ]; then
	log_err "target database ${DB_NAME} does not exist on ${TARG_HOST} and --create-target is false"
	exit 1
fi

log "source ${DB_NAME}@${SRC_HOST} doc_count=${SRC_DOCS}; target doc_count=${TARG_DOCS_BEFORE}"

if [ "${DRY_RUN}" = "true" ]; then
	log_dry "REPLICATE ${DB_NAME}: ${SRC_HOST} -> ${TARG_HOST} via ${REP_HOST} (continuous=${CONTINUOUS}, create_target=${CREATE_TARGET})"
	log "FIN: ${DB_NAME}: dry run, nothing changed"
	cdb_result "rep_dry_run=true" "rep_docs_updated=0" "rep_secs=0"
	exit 0
fi

# ---------------------------------------------------------------------------
# replicate
# ---------------------------------------------------------------------------

REP_T0="$(date +%s)"
if ! couch_replicate "${REP_SVR}" "${SRC_SVR}/${DB_NAME}" "${TARG_SVR}/${DB_NAME}" "${CONTINUOUS}" "${CREATE_TARGET}"; then
	log_err "FIN: ${DB_NAME}: ${SRC_HOST} -> ${TARG_HOST} FAILED"
	cdb_result "rep_failed=true" "rep_secs=$(( $(date +%s) - REP_T0 ))"
	exit 1
fi
REP_SECS=$(( $(date +%s) - REP_T0 ))

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------

if [ "${CONTINUOUS}" = "true" ]; then
	# http 202 means the job was QUEUED, before CouchDB has tried to reach the
	# source. A continuous replication can be accepted and then fail
	# asynchronously, so the scheduler is the only thing worth believing.
	log_warn "${DB_NAME}: continuous replication accepted (http 202) - accepted is not working"
	if [ -n "${CDB_REP_LOCAL_ID}" ]; then
		# Print it: this id is the only handle for cancelling a transient job.
		log "${DB_NAME}: replication_id=${CDB_REP_LOCAL_ID}"
		log "${DB_NAME}: cancel with POST ${REP_HOST}/_replicate {\"replication_id\":\"${CDB_REP_LOCAL_ID}\",\"cancel\":true}"
	fi
	if couch_req GET "${REP_SVR}/_scheduler/jobs"; then
		# The scheduler reports source/target as full URLs with a trailing slash
		# ("http://host:5984/mydb/"), so match on the path segment - and with
		# grep -F, because a database name may legally contain + ( ) $ - all of
		# which are regex metacharacters.
		if printf '%s' "${CDB_BODY}" | grep -qF "/${DB_NAME}/"; then
			log "${DB_NAME}: present in _scheduler/jobs on ${REP_HOST}"
		else
			log_warn "${DB_NAME}: not visible in _scheduler/jobs on ${REP_HOST} yet"
		fi
	else
		log_warn "${DB_NAME}: could not read _scheduler/jobs on ${REP_HOST}: http=${CDB_HTTP_CODE}"
	fi
	log "FIN: ${DB_NAME}: ${SRC_HOST} -> ${TARG_HOST} queued (continuous)"
	cdb_result "rep_continuous=true" "rep_secs=${REP_SECS}"
	exit 0
fi

# One-shot: 200 arrived only after the copy finished, so the counts are real.
if ! couch_fetch_doc_count "${TARG_SVR}" "${DB_NAME}"; then
	log_err "${DB_NAME}: replication reported ok but the target is unreadable: $(describe_last_error)"
	exit 1
fi
TARG_DOCS_AFTER="${CDB_DOC_COUNT}"

# What this run did, then the lifetime totals - labelled, because reading the
# totals as this run's work is the mistake this wording exists to prevent.
if [ "${CDB_REP_NO_CHANGES}" = "true" ]; then
	log "${DB_NAME}: 0 docs updated in ${REP_SECS}s - already current, CouchDB copied nothing"
else
	log "${DB_NAME}: ${CDB_REP_DOCS_UPDATED:-?} docs updated in ${REP_SECS}s"
fi
log "${DB_NAME}: lifetime totals docs_read=${CDB_REP_DOCS_READ:-0} docs_written=${CDB_REP_DOCS_WRITTEN:-0} doc_write_failures=${CDB_REP_WRITE_FAILURES:-0} (cumulative, NOT this run)"

cdb_result \
	"rep_docs_updated=${CDB_REP_DOCS_UPDATED:-0}" \
	"rep_no_changes=${CDB_REP_NO_CHANGES}" \
	"rep_secs=${REP_SECS}" \
	"rep_session=${CDB_REP_SESSION_ID}" \
	"rep_docs_after=${TARG_DOCS_AFTER}"

if [ "${TARG_DOCS_AFTER}" != "${SRC_DOCS}" ]; then
	# Not fatal on its own - a document deleted at the source leaves the target
	# doc_count lower until the tombstone replicates, and writes at the source
	# during the copy move the number. Worth a line in the log either way.
	log_warn "${DB_NAME}: target doc_count=${TARG_DOCS_AFTER} differs from source doc_count=${SRC_DOCS}"
fi

log "FIN: ${DB_NAME}: ${SRC_HOST} -> ${TARG_HOST} OK (target doc_count ${TARG_DOCS_BEFORE} -> ${TARG_DOCS_AFTER})"
exit 0
