#!/bin/bash
#
# couchdb-repv-common.sh - shared library for the inventory-driven CouchDB
#                         replication / versioning scripts.
#
# script location /opt/couchdb-repv/couchdb-repv-common.sh
#
# This file is sourced, never executed. It provides:
#
#   logging      log / log_err / log_warn      - stdout AND syslog, credential-redacted
#   secrets      env_load                      - parse a .env-style file whose keys are
#                                                hostnames (so they can NOT be sourced)
#   servers      servers_load / resolve_server - the alias table, so an inventory row
#                                                names a server instead of spelling out
#                                                a credentialled URL on every line
#   policy       parse_keep                    - the one 'keep' column, eg 7/5/12/7
#   redaction    redact / url_with_creds       - keep passwords out of every log line
#   http         couch_req and friends         - curl wrappers that judge on HTTP status
#   retention    retention_select              - PURE function, restic-style forget
#
# Requires: bash 4.x (associative arrays), curl, date (GNU), logger.
#

# Guard against double-sourcing.
[ -n "${CDB_COMMON_SOURCED:-}" ] && return 0
CDB_COMMON_SOURCED=1

# -e fights the accumulate-failures-and-continue pattern these scripts depend on:
# a single failed database must not abort the run. Errors are checked explicitly.
set -uo pipefail

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
#
# The usual `exec 1> >(logger -s -t $(basename $0) 2>&1)` idiom can lose the
# tail of the output - including the FIN: summary - because the script can exit
# before the backgrounded logger has flushed. An explicit function writing to
# both destinations is deterministic.
#
# CDB_LOG_TAG lets a parent script (the inventory engine) put every line from
# its child components under one syslog tag, and stops the same line being
# logged twice when the parent relays a child's stdout.

CDB_LOG_TAG="${CDB_LOG_TAG:-}"
CDB_SYSLOG="${CDB_SYSLOG:-true}"

cdb_log_init () {
	# usage: cdb_log_init <default-tag>
	if [ -z "${CDB_LOG_TAG}" ]; then
		CDB_LOG_TAG="$1"
	fi
	export CDB_LOG_TAG
}

_cdb_emit () {
	# usage: _cdb_emit <syslog-priority> <level-label> <message...>
	local prio="$1"; shift
	local level="$1"; shift
	local msg
	msg="$(redact "$*")"

	# stderr, not stdout: several functions here return their value on stdout,
	# and a log line raised inside one of them would otherwise be captured by
	# the caller's $( ) and vanish from the operator's view. Both streams reach
	# the screen and the cron mail, so nothing is lost by using stderr.
	printf '%s %s: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${level}" "${msg}" >&2

	if [ "${CDB_SYSLOG}" = "true" ] && command -v logger >/dev/null 2>&1; then
		logger -t "${CDB_LOG_TAG:-couchdb-rep}" -p "${prio}" -- "${level}: ${msg}" 2>/dev/null
	fi
}

log ()      { _cdb_emit user.info   INFO  "$@"; }
log_warn () { _cdb_emit user.warning WARN "$@"; }
log_err ()  { _cdb_emit user.err    ERROR "$@"; }
log_dry ()  { _cdb_emit user.info   "DRY-RUN" "$@"; }

# ---------------------------------------------------------------------------
# redaction
# ---------------------------------------------------------------------------
#
# Turns  http://admin:hunter2@host:5984/db  into  http://***:***@host:5984/db
# Applied to EVERY log line, so a password can never reach the screen or syslog
# even if a URL is interpolated into a message by accident.

redact () {
	local s="$*"
	# shellcheck disable=SC2001  # the substitution needs a regex, not a glob
	printf '%s' "$(printf '%s' "${s}" | sed -E 's#(https?://)[^/@[:space:]]*@#\1***:***@#g')"
}

# ---------------------------------------------------------------------------
# secrets: the .env-style file
# ---------------------------------------------------------------------------
#
# Keys are hostnames or IP addresses, e.g.
#
#     couchdb.example.com_USER=admin
#     couchdb.example.com_PASS=CHANGE_ME
#     203.0.113.10_USER=admin
#     203.0.113.10_PASS=CHANGE_ME
#
# Those contain dots, so they are NOT valid shell identifiers: this file can
# never be `source`d and no `eval` is used anywhere. It is parsed line by line
# into an associative array.

declare -gA CDB_SECRET=()

env_load () {
	# usage: env_load <file> [allow_insecure]
	local file="$1"
	local allow_insecure="${2:-false}"
	local line key value mode count=0

	if [ ! -f "${file}" ]; then
		log_err "env file not found: ${file}"
		return 1
	fi
	if [ ! -r "${file}" ]; then
		log_err "env file not readable: ${file}"
		return 1
	fi

	# A credentials file readable by group or other is a finding in itself.
	mode="$(stat -c '%a' "${file}" 2>/dev/null)"
	if [ -n "${mode}" ]; then
		# pad to 3 digits so ${mode: -2} is meaningful for modes like 600 vs 0600
		mode="${mode: -3}"
		if [ "${mode:1:1}" != "0" ] || [ "${mode:2:1}" != "0" ]; then
			if [ "${allow_insecure}" = "true" ]; then
				log_warn "env file ${file} is mode ${mode} (group/other readable) - continuing, --allow-insecure-env given"
			else
				log_err "env file ${file} is mode ${mode}; it holds passwords and must not be group/other readable"
				log_err "fix with: chmod 600 ${file}   (or pass --allow-insecure-env)"
				return 1
			fi
		fi
	fi

	while IFS= read -r line || [ -n "${line}" ]; do
		line="${line%$'\r'}"                       # tolerate CRLF files
		line="${line#"${line%%[![:space:]]*}"}"    # ltrim
		[ -z "${line}" ] && continue
		[ "${line:0:1}" = "#" ] && continue

		# export PREFIX is accepted for people used to real .env files
		if [ "${line:0:7}" = "export " ]; then
			line="${line:7}"
			line="${line#"${line%%[![:space:]]*}"}"
		fi

		# ':' is admitted so a key may be port-qualified - 192.168.66.7:6984_USER -
		# which resolve_server prefers over the bare hostname when both are present.
		# Almost every fleet only ever needs the bare hostname form.
		if [[ ! "${line}" =~ ^([A-Za-z0-9][A-Za-z0-9._:-]*_(USER|PASS))=(.*)$ ]]; then
			log_warn "env file ${file}: ignoring unparsable line: $(redact "${line%%=*}")=..."
			continue
		fi

		key="${BASH_REMATCH[1]}"
		value="${BASH_REMATCH[3]}"

		# strip one layer of matching quotes; leave everything else verbatim so
		# passwords containing = # $ { } are preserved exactly
		if [ "${#value}" -ge 2 ]; then
			if [ "${value:0:1}" = '"' ] && [ "${value: -1}" = '"' ]; then
				value="${value:1:${#value}-2}"
			elif [ "${value:0:1}" = "'" ] && [ "${value: -1}" = "'" ]; then
				value="${value:1:${#value}-2}"
			fi
		fi

		CDB_SECRET["${key}"]="${value}"
		count=$((count + 1))
	done < "${file}"

	if [ "${count}" -eq 0 ]; then
		log_err "env file ${file} contained no usable <host>_USER / <host>_PASS entries"
		return 1
	fi

	log "loaded ${count} credential entries from ${file}"
	return 0
}

# percent-encode a userinfo component (RFC 3986 sub-delims are legal unencoded,
# but ':' '@' '/' '?' '#' '%' are not and would silently corrupt the URL).
url_encode_userinfo () {
	local s="$1" out="" i c
	for (( i = 0; i < ${#s}; i++ )); do
		c="${s:i:1}"
		case "${c}" in
			[A-Za-z0-9._~-]) out+="${c}" ;;
			*)               out+="$(printf '%%%02X' "'${c}")" ;;
		esac
	done
	printf '%s' "${out}"
}

# split_url <url> - sets CDB_URL_SCHEME CDB_URL_USER CDB_URL_PASS CDB_URL_HOSTPORT
# and CDB_URL_BASE (scheme://hostport, no credentials).
split_url () {
	local url="$1" rest userinfo
	CDB_URL_SCHEME=""; CDB_URL_USER=""; CDB_URL_PASS=""; CDB_URL_HOSTPORT=""; CDB_URL_BASE=""

	if [[ ! "${url}" =~ ^(https?)://(.*)$ ]]; then
		log_err "not an http(s) URL: $(redact "${url}")"
		return 1
	fi
	CDB_URL_SCHEME="${BASH_REMATCH[1]}"
	rest="${BASH_REMATCH[2]}"
	rest="${rest%/}"                       # tolerate a trailing slash

	if [[ "${rest}" == *"@"* ]]; then
		# Split on the LAST '@': a password may legitimately contain one, and a
		# host name may not. Then split the userinfo on the FIRST ':', because a
		# password may contain one and a user name may not. This is curl's rule.
		CDB_URL_HOSTPORT="${rest##*@}"
		userinfo="${rest%@*}"
		if [[ "${userinfo}" == *":"* ]]; then
			CDB_URL_USER="${userinfo%%:*}"
			CDB_URL_PASS="${userinfo#*:}"
		else
			CDB_URL_USER="${userinfo}"
		fi
	else
		CDB_URL_HOSTPORT="${rest}"
	fi

	if [ -z "${CDB_URL_HOSTPORT}" ] || [[ "${CDB_URL_HOSTPORT}" == */* ]]; then
		log_err "URL must be scheme://[user:pass@]host[:port] with no path: $(redact "${url}")"
		return 1
	fi

	# shellcheck disable=SC2034  # part of this function's documented output
	CDB_URL_BASE="${CDB_URL_SCHEME}://${CDB_URL_HOSTPORT}"
	return 0
}

# normalise_url <url> - percent-encodes the credentials and drops any trailing
# slash, so the result is safe to concatenate with /dbname.
normalise_url () {
	local url="$1"
	split_url "${url}" || return 1
	if [ -n "${CDB_URL_USER}" ]; then
		printf '%s://%s:%s@%s' \
			"${CDB_URL_SCHEME}" \
			"$(url_encode_userinfo "${CDB_URL_USER}")" \
			"$(url_encode_userinfo "${CDB_URL_PASS}")" \
			"${CDB_URL_HOSTPORT}"
	else
		printf '%s://%s' "${CDB_URL_SCHEME}" "${CDB_URL_HOSTPORT}"
	fi
	return 0
}

# host_of <url> - the host[:port], used for messages and for the env key hint.
host_of () {
	split_url "$1" >/dev/null 2>&1 || { printf 'unknown-host'; return 1; }
	printf '%s' "${CDB_URL_HOSTPORT}"
}

# ---------------------------------------------------------------------------
# server aliases: the servers table
# ---------------------------------------------------------------------------
#
# An inventory names a server by a short alias; this table says what the alias
# means. Without it, every row would carry a full credentialled URL in three of
# its columns - the same handful of servers repeated on every line, which is a
# denormalised format that is neither readable nor safe to commit.
#
#   alias,url
#   bak2,http://192.168.66.11:5984
#   cloud,http://203.0.113.10:5984
#
# The table holds NO credentials, which is the point of keeping it separate from
# the --env file: it is safe to commit, so "which box is the backup target for
# orders?" stays answerable from git and reviewable in a diff. The
# passwords are filled in from the env file by hostname - see resolve_server.

declare -gA CDB_SERVER=()        # alias     -> url exactly as the table wrote it
declare -gA CDB_SERVER_ALIAS=()  # host:port -> alias, for log lines only

# servers_known - the loaded aliases, sorted, for an error message.
servers_known () {
	if [ "${#CDB_SERVER[@]}" -eq 0 ]; then
		printf '(none)'
		return 0
	fi
	printf '%s' "$(printf '%s\n' "${!CDB_SERVER[@]}" | sort | paste -sd' ' -)"
}

# servers_mapping - "alias -> host:port, ..." for the one line a run logs to say
# what its aliases mean. Sorted, so two runs of the same table read the same.
# Never the URL: that would put credentials one redaction bug away from syslog.
servers_mapping () {
	local a first=1 out=""
	if [ "${#CDB_SERVER[@]}" -eq 0 ]; then
		printf '(none)'
		return 0
	fi
	while IFS= read -r a; do
		[ -z "${a}" ] && continue
		[ "${first}" -eq 1 ] || out+=", "
		first=0
		out+="${a} -> $(host_of "${CDB_SERVER[${a}]}")"
	done < <(printf '%s\n' "${!CDB_SERVER[@]}" | sort)
	printf '%s' "${out}"
}

# servers_load <file>
#
# Reads the alias table. Same shape as the inventory: the header row is
# authoritative so a renamed column is a startup error rather than a silently
# shifted field, blank and # lines are skipped, and no quoting is needed because
# neither an alias nor these URLs can contain a comma.
servers_load () {
	local file="$1"
	local line trimmed alias url hostport k c
	local lineno=0 header_n=0 count=0 bad=0
	local -a fields=()
	local -A col_idx=()

	if [ ! -f "${file}" ]; then
		log_err "servers file not found: ${file}"
		return 1
	fi
	if [ ! -r "${file}" ]; then
		log_err "servers file not readable: ${file}"
		return 1
	fi

	while IFS= read -r line || [ -n "${line}" ]; do
		lineno=$((lineno + 1))
		line="${line%$'\r'}"
		trimmed="${line#"${line%%[![:space:]]*}"}"
		[ -z "${trimmed}" ] && continue
		[ "${trimmed:0:1}" = "#" ] && continue

		IFS=',' read -r -a fields <<< "${line}"
		for k in "${!fields[@]}"; do
			fields[k]="${fields[k]#"${fields[k]%%[![:space:]]*}"}"
			fields[k]="${fields[k]%"${fields[k]##*[![:space:]]}"}"
		done

		if [ "${header_n}" -eq 0 ]; then
			header_n="${#fields[@]}"
			for k in "${!fields[@]}"; do col_idx["${fields[k]}"]="${k}"; done
			for c in alias url; do
				if [ -z "${col_idx[${c}]+isset}" ]; then
					log_err "servers file ${file} line ${lineno}: header is missing column: ${c}"
					log_err "expected header: alias,url"
					return 1
				fi
			done
			continue
		fi

		if [ "${#fields[@]}" -ne "${header_n}" ]; then
			log_err "servers file ${file} line ${lineno}: has ${#fields[@]} fields, header has ${header_n}"
			bad=1
			continue
		fi

		alias="${fields[${col_idx[alias]}]}"
		url="${fields[${col_idx[url]}]}"

		# The charset is what tells an alias from a URL in the inventory: it
		# admits neither ':' nor '/', so an alias can never contain '://' and
		# the discriminator in resolve_server cannot be fooled.
		if [[ ! "${alias}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
			log_err "servers file ${file} line ${lineno}: '${alias}' is not a valid alias (letters, digits, . _ - ; must not start with . _ -)"
			bad=1
			continue
		fi
		if [ -n "${CDB_SERVER[${alias}]+isset}" ]; then
			# Last-wins would mean an accidental duplicate silently reroutes
			# every row that names it, which for a backup job is the kind of
			# quiet mistake that is only found when a restore is attempted.
			log_err "servers file ${file} line ${lineno}: duplicate alias '${alias}'"
			bad=1
			continue
		fi
		if [ -z "${url}" ]; then
			log_err "servers file ${file} line ${lineno}: alias '${alias}' has an empty url"
			bad=1
			continue
		fi
		# Refused, not warned about. Credentials come from the --env file and
		# nowhere else; a second source would mean two places to look when a
		# password stops working, and would put a secret in the one config file
		# that is meant to be committable.
		if [[ "${url}" == *"@"* ]]; then
			log_err "servers file ${file} line ${lineno}: '${alias}' has credentials in its url"
			log_err "put them in the --env file as ${alias}'s hostname _USER / _PASS instead"
			bad=1
			continue
		fi
		if ! split_url "${url}" >/dev/null 2>&1; then
			log_err "servers file ${file} line ${lineno}: alias '${alias}' has a bad url: $(redact "${url}")"
			bad=1
			continue
		fi

		CDB_SERVER["${alias}"]="${url}"
		# First alias wins the reverse map: two aliases may legitimately point
		# at one box (it is the target of one row and the rep-svr of another),
		# and the log label should not depend on which row is being processed.
		hostport="${CDB_URL_HOSTPORT}"
		[ -n "${CDB_SERVER_ALIAS[${hostport}]+isset}" ] || CDB_SERVER_ALIAS["${hostport}"]="${alias}"
		count=$((count + 1))
	done < "${file}"

	if [ "${header_n}" -eq 0 ]; then
		log_err "servers file ${file} has no header row"
		return 1
	fi
	if [ "${bad}" -ne 0 ]; then
		log_err "servers file ${file}: ${bad} bad entr(ies) - refusing to run against a half-understood server table"
		return 1
	fi
	if [ "${count}" -eq 0 ]; then
		log_err "servers file ${file} defines no aliases"
		return 1
	fi

	log "loaded ${count} server alias(es) from ${file}"
	return 0
}

# resolve_server <alias>
#
# Turns one inventory server field into a full, credentialled, normalised URL.
# There is exactly one path and no discriminator to get wrong:
#
#   alias -> servers table -> credentials from the env file, by hostname
#
# A server field is ALWAYS an alias. An inventory never carries a URL and never
# carries a credential, which is what lets it be short enough to read and safe
# enough to commit. Anything that is not a known alias is an error naming the
# aliases that are.
#
# The lookup tries <host:port>_USER before <host>_USER (and the same for _PASS),
# so two CouchDBs on one box can hold different passwords. Almost every fleet
# only needs the plain hostname key, which is what repv-env.example shows.
#
# Prints the resolved URL on stdout; returns 1, with a specific reason, on an
# unknown alias, a missing credential, or a URL the table should never have
# accepted.
resolve_server () {
	local value="$1"
	local url hostport host key found_key="" user pass

	if [ -z "${value}" ]; then
		log_err "empty server field"
		return 1
	fi

	if [ -z "${CDB_SERVER[${value}]+isset}" ]; then
		if [ "${#CDB_SERVER[@]}" -eq 0 ]; then
			log_err "no servers table is loaded, so '${value}' cannot be resolved - pass --servers FILE"
		else
			log_err "unknown server alias '${value}' - the servers file defines: $(servers_known)"
		fi
		return 1
	fi
	url="${CDB_SERVER[${value}]}"

	split_url "${url}" || return 1

	hostport="${CDB_URL_HOSTPORT}"
	# Strip the port for the fallback key, tolerating a bracketed IPv6 literal,
	# where the colons are part of the address.
	if [ "${hostport:0:1}" = "[" ]; then
		host="${hostport%%]*}]"
	else
		host="${hostport%%:*}"
	fi

	user=""; pass=""
	for key in "${hostport}" "${host}"; do
		if [ -n "${CDB_SECRET[${key}_USER]+isset}" ] || [ -n "${CDB_SECRET[${key}_PASS]+isset}" ]; then
			found_key="${key}"
			user="${CDB_SECRET[${key}_USER]:-}"
			pass="${CDB_SECRET[${key}_PASS]:-}"
			break
		fi
	done

	if [ -z "${found_key}" ]; then
		log_err "server alias '${value}' (${hostport}) has no credentials: the env file needs ${host}_USER and ${host}_PASS"
		return 1
	fi
	if [ -z "${user}" ] || [ -z "${pass}" ]; then
		log_err "server alias '${value}' (${hostport}): the env file has ${found_key}_USER or ${found_key}_PASS but not both"
		return 1
	fi

	normalise_url "${CDB_URL_SCHEME}://${user}:${pass}@${CDB_URL_HOSTPORT}" || return 1
	return 0
}

# server_label <resolved-url> - what to call this server in a log line: its
# alias when the servers table knows one, otherwise the host:port. This is the
# payoff for aliases in the FIN: summary, where a column of 'bak1' reads at a
# glance and a column of IP addresses does not.
server_label () {
	local hostport
	hostport="$(host_of "$1")" || { printf '%s' "${hostport}"; return 1; }
	if [ -n "${CDB_SERVER_ALIAS[${hostport}]+isset}" ]; then
		printf '%s' "${CDB_SERVER_ALIAS[${hostport}]}"
	else
		printf '%s' "${hostport}"
	fi
}

# ---------------------------------------------------------------------------
# http
# ---------------------------------------------------------------------------
#
# curl's exit code only reports transport failure - it exits 0 whenever it
# completes the round trip - so the HTTP status and CouchDB's body are the only
# things that distinguish success from a rejection. Note that CouchDB reports
# most replication problems as HTTP 500, not 4xx: a missing source database is
# 500 {"error":"db_not_found"} and bad credentials are
# 500 {"error":"replication_auth_error"}.

CDB_HTTP_CODE=""
CDB_BODY=""
CDB_CURL_RC=0

# Two separate budgets, because they measure different things:
#
#   CDB_TIMEOUT      metadata calls (GET /db, _all_dbs, DELETE) - seconds
#   CDB_REP_TIMEOUT  the _replicate POST itself. A one-shot replication does not
#                    respond until it has FINISHED copying, so a multi-GB
#                    database can legitimately hold the connection for hours.
#                    Cutting it short would abort curl while CouchDB carried on
#                    server-side, reporting a failure for a copy that succeeded.
#                    Default 24h: bounded, but never in the way of a real run.
CDB_TIMEOUT="${CDB_TIMEOUT:-60}"
CDB_REP_TIMEOUT="${CDB_REP_TIMEOUT:-86400}"

couch_req () {
	# usage: couch_req <METHOD> <url> [json-body] [max-time-override]
	local method="$1" url="$2" body="${3:-}" maxtime="${4:-${CDB_TIMEOUT}}"
	local raw
	local -a args=( -sS -X "${method}"
	                --connect-timeout 15
	                --max-time "${maxtime}"
	                -H 'Content-Type: application/json'
	                -w $'\n%{http_code}' )

	CDB_HTTP_CODE=""; CDB_BODY=""; CDB_CURL_RC=0

	if [ -n "${body}" ]; then
		args+=( -d "${body}" )
	fi

	raw="$(curl "${args[@]}" "${url}" 2>&1)"
	CDB_CURL_RC=$?

	if [ "${CDB_CURL_RC}" -ne 0 ]; then
		# On a transport failure -w still emits its "000" line. Strip it and any
		# trailing blank line so the log carries curl's message and nothing else.
		raw="${raw%$'\n'000}"
		raw="${raw%$'\n'}"
		CDB_BODY="$(redact "${raw}")"
		return 1
	fi

	CDB_HTTP_CODE="${raw##*$'\n'}"
	CDB_BODY="${raw%$'\n'*}"

	case "${CDB_HTTP_CODE}" in
		2*) return 0 ;;
		*)  return 1 ;;
	esac
}

# json_field <body> <key> - pull a scalar out of a flat CouchDB response
# without requiring jq (these scripts get rsynced to hosts that may not have
# it). Handles "key":123, "key":true and "key":"str".
json_field () {
	local body="$1" key="$2" out
	out="$(printf '%s' "${body}" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\(\"[^\"]*\"\|[A-Za-z0-9.eE+-]*\)" | head -n1)"
	[ -z "${out}" ] && return 1
	out="${out#*:}"
	out="${out#"${out%%[![:space:]]*}"}"
	out="${out%\"}"
	out="${out#\"}"
	printf '%s' "${out}"
	return 0
}

# json_field_all <body> <key> - every NUMERIC value for <key>, in document
# order, one per line.
#
# The /_replicate reply carries one docs_read/docs_written per history entry,
# newest first, so line 1 is the most recent session and line 2 the one before
# it. Subtracting the two is the only way to get this run's work out of a reply
# whose counters are cumulative - see the docs_read note in CLAUDE.md.
json_field_all () {
	printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[0-9][0-9]*" | sed 's/.*:[[:space:]]*//'
}

# ---------------------------------------------------------------------------
# result channel - how a child hands structured numbers back to a parent
# ---------------------------------------------------------------------------
#
# couchdb-repv.sh runs couchdb-repv-version.sh and couchdb-repv-replicate.sh as
# separate processes and only relays their output, so nothing a child computes
# is visible to it. Rather than have the parent scrape the human log - which
# would turn every wording change into a parsing bug - a child appends
# key=value lines here and the parent reads them.
#
# CDB_RESULT_FILE unset means nobody is collecting and this is a no-op, so the
# child scripts remain perfectly usable on their own.
cdb_result () {
	[ -n "${CDB_RESULT_FILE:-}" ] || return 0
	printf '%s\n' "$@" >> "${CDB_RESULT_FILE}" 2>/dev/null || true
}

# json_array_of_strings <body> - one element per line.
# CouchDB database names are restricted to ^[a-z][a-z0-9_$()+/-]*$ plus the
# leading-underscore system databases, so no element can contain a quote or a
# backslash and this simple split is exact.
json_array_of_strings () {
	printf '%s' "$1" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[][]//g' -e 's/^"//' -e 's/"$//' | grep -v '^[[:space:]]*$'
}

# These two set a global instead of printing their result, and callers must NOT
# wrap them in $( ). A command substitution runs the function in a subshell, so
# CDB_HTTP_CODE / CDB_BODY / CDB_CURL_RC set inside it are discarded when the
# subshell exits - leaving the caller's error branch with nothing to report and
# printing "http=:" with no detail. Setting a global keeps the diagnostics.

CDB_ALL_DBS=""
CDB_DOC_COUNT=""

couch_fetch_all_dbs () {
	# usage: couch_fetch_all_dbs <server-url>   -> sets CDB_ALL_DBS, one db per line
	local svr="$1"
	CDB_ALL_DBS=""
	if ! couch_req GET "${svr}/_all_dbs"; then
		return 1
	fi
	if [ "${CDB_BODY:0:1}" != "[" ]; then
		CDB_BODY="unexpected _all_dbs response: $(redact "${CDB_BODY}")"
		return 1
	fi
	# shellcheck disable=SC2034  # read by the scripts that source this library
	CDB_ALL_DBS="$(json_array_of_strings "${CDB_BODY}")"
	return 0
}

couch_db_exists () {
	# usage: couch_db_exists <server-url> <db>
	couch_req GET "$1/$2" >/dev/null 2>&1
	[ "${CDB_HTTP_CODE}" = "200" ]
}

couch_fetch_doc_count () {
	# usage: couch_fetch_doc_count <server-url> <db>   -> sets CDB_DOC_COUNT
	CDB_DOC_COUNT=""
	if ! couch_req GET "$1/$2"; then
		return 1
	fi
	# shellcheck disable=SC2034  # read by the scripts that source this library
	CDB_DOC_COUNT="$(json_field "${CDB_BODY}" doc_count)" || return 1
	return 0
}

# describe_last_error - one line explaining why the last couch_req failed,
# whichever way it failed. Saves every call site repeating the same branch.
describe_last_error () {
	if [ "${CDB_CURL_RC}" -ne 0 ]; then
		printf 'curl rc=%s: %s' "${CDB_CURL_RC}" "${CDB_BODY}"
	else
		printf 'http=%s: %s' "${CDB_HTTP_CODE}" "$(redact "${CDB_BODY}")"
	fi
}

# json_escape_string <s> - for values we interpolate into a payload.
json_escape_string () {
	local s="$1"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	printf '%s' "${s}"
}

# couch_replicate <rep-svr> <source-url> <target-url> <continuous> [create_target]
#
# POSTs to <rep-svr>/_replicate. The rep-svr is the node that PERFORMS the
# replication and must be able to reach both source and target - which is why
# the inventory carries it per row rather than assuming the target.
#
# Sets CDB_REP_DOCS_READ / CDB_REP_DOCS_WRITTEN / CDB_REP_WRITE_FAILURES on a
# completed one-shot run.
# shellcheck disable=SC2034  # read by the scripts that source this library
CDB_REP_DOCS_READ=""
# shellcheck disable=SC2034  # read by the scripts that source this library
CDB_REP_DOCS_WRITTEN=""
CDB_REP_WRITE_FAILURES=""
# Documents actually written by THIS call, derived rather than reported: see
# the no_changes / history subtraction in couch_replicate below.
# shellcheck disable=SC2034  # read by the scripts that source this library
CDB_REP_DOCS_UPDATED=""
# true when CouchDB said the checkpoint was already current and it did nothing.
# shellcheck disable=SC2034  # read by the scripts that source this library
CDB_REP_NO_CHANGES=""
# shellcheck disable=SC2034  # read by the scripts that source this library
CDB_REP_SESSION_ID=""
# The replication id of a transient continuous job. Cancel one with
#   POST <rep-svr>/_replicate {"replication_id":"<id>","cancel":true}
CDB_REP_LOCAL_ID=""

couch_replicate () {
	local rep_svr="$1" source="$2" target="$3" continuous="$4" create_target="${5:-true}"
	local payload ok

	CDB_REP_DOCS_READ=""; CDB_REP_DOCS_WRITTEN=""; CDB_REP_WRITE_FAILURES=""; CDB_REP_LOCAL_ID=""
	CDB_REP_DOCS_UPDATED=""; CDB_REP_NO_CHANGES=""; CDB_REP_SESSION_ID=""

	payload="$(printf '{"source":"%s","target":"%s","connection_timeout":60000,"continuous":%s,"create_target":%s}' \
		"$(json_escape_string "${source}")" \
		"$(json_escape_string "${target}")" \
		"${continuous}" "${create_target}")"

	if ! couch_req POST "${rep_svr}/_replicate" "${payload}" "${CDB_REP_TIMEOUT}"; then
		if [ "${CDB_CURL_RC}" -eq 28 ]; then
			log_err "replication POST to $(redact "${rep_svr}")/_replicate timed out after ${CDB_REP_TIMEOUT}s"
			log_err "the copy is probably STILL RUNNING server-side - check _scheduler/jobs before retrying, and raise --rep-timeout"
		elif [ "${CDB_CURL_RC}" -ne 0 ]; then
			log_err "curl rc=${CDB_CURL_RC} posting to $(redact "${rep_svr}")/_replicate: ${CDB_BODY}"
		else
			log_err "http=${CDB_HTTP_CODE} from $(redact "${rep_svr}")/_replicate: $(redact "${CDB_BODY}")"
		fi
		return 1
	fi

	if [ "${continuous}" = "true" ]; then
		# 202 means QUEUED, not working. The caller must verify separately.
		# shellcheck disable=SC2034  # read by the scripts that source this library
		CDB_REP_LOCAL_ID="$(json_field "${CDB_BODY}" _local_id || true)"
		log "http=${CDB_HTTP_CODE} (continuous accepted, not yet proven): $(redact "${CDB_BODY}")"
		return 0
	fi

	# One-shot: 200 arrives only after the replication has actually finished, so
	# the body is trustworthy - but only if it says ok and wrote nothing badly.
	ok="$(json_field "${CDB_BODY}" ok || true)"
	# shellcheck disable=SC2034  # read by the scripts that source this library
	CDB_REP_DOCS_READ="$(json_field "${CDB_BODY}" docs_read || true)"
	# shellcheck disable=SC2034  # read by the scripts that source this library
	CDB_REP_DOCS_WRITTEN="$(json_field "${CDB_BODY}" docs_written || true)"
	CDB_REP_WRITE_FAILURES="$(json_field "${CDB_BODY}" doc_write_failures || true)"

	# ---- what did THIS call actually do? ------------------------------------
	#
	# docs_read/docs_written above are CUMULATIVE LIFETIME TOTALS for this
	# replication, not the work of this call, and a call that finds its
	# checkpoint current replays the previous session's history verbatim - so an
	# idle run and the run that copied everything print the identical number.
	# Two things separate them:
	#
	#   1. no_changes:true, which CouchDB sets only when it did nothing at all.
	#   2. the history array, newest first: this session's work is its running
	#      total minus the previous entry's.
	#
	# shellcheck disable=SC2034  # read by the scripts that source this library
	CDB_REP_SESSION_ID="$(json_field "${CDB_BODY}" session_id || true)"

	if [ -n "$(json_field "${CDB_BODY}" no_changes || true)" ]; then
		# shellcheck disable=SC2034  # read by the scripts that source this library
		CDB_REP_NO_CHANGES="true"
		# shellcheck disable=SC2034  # read by the scripts that source this library
		CDB_REP_DOCS_UPDATED=0
	else
		# shellcheck disable=SC2034  # read by the scripts that source this library
		CDB_REP_NO_CHANGES="false"
		local -a _wrote=()
		mapfile -t _wrote < <(json_field_all "${CDB_BODY}" docs_written)
		case "${#_wrote[@]}" in
			0) CDB_REP_DOCS_UPDATED="" ;;
			1) CDB_REP_DOCS_UPDATED="${_wrote[0]}" ;;
			*) CDB_REP_DOCS_UPDATED=$(( _wrote[0] - _wrote[1] )) ;;
		esac
		# A negative delta would mean the history was pruned or reordered under
		# us. Report the raw total rather than a nonsense number, and say so.
		if [ -n "${CDB_REP_DOCS_UPDATED}" ] && [ "${CDB_REP_DOCS_UPDATED}" -lt 0 ]; then
			log_warn "replication history is not newest-first (${_wrote[0]} then ${_wrote[1]}); reporting the lifetime total instead of this run's work"
			CDB_REP_DOCS_UPDATED="${_wrote[0]}"
		fi
	fi

	if [ "${ok}" != "true" ]; then
		log_err "replication did not report ok:true - http=${CDB_HTTP_CODE} body=$(redact "${CDB_BODY}")"
		return 1
	fi
	if [ -n "${CDB_REP_WRITE_FAILURES}" ] && [ "${CDB_REP_WRITE_FAILURES}" != "0" ]; then
		log_err "replication reported doc_write_failures=${CDB_REP_WRITE_FAILURES}"
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# retention - restic-style forget
# ---------------------------------------------------------------------------
#
# retention_select is a PURE function: stamps in, decisions out, no network and
# no globals mutated. That is deliberate - it is the only part of this system
# that deletes data, so it has to be testable in isolation.
#
#   usage: retention_select <keep-daily> <keep-weekly> <keep-monthly> <keep-yearly>
#          stamps (YYYYMMDD-HHMMSS) arrive on stdin, one per line, any order
#   output: "KEEP <stamp> <reasons>" / "DELETE <stamp>", newest first
#
# Semantics match `restic forget`: walking newest -> oldest, a snapshot is kept
# by a bucket type when it is the first one seen in a NEW bucket of that type
# and that type has keeps left. So these are "the last N snapshots that open a
# new day/week/month/year", not "the last N calendar days" - gaps in the series
# do not consume keeps.
#
# The newest snapshot is always kept, whatever the policy says.

retention_select () {
	local keep_daily="$1" keep_weekly="$2" keep_monthly="$3" keep_yearly="$4"
	local -a stamps=() keys=()
	local s line

	while IFS= read -r line; do
		line="${line%$'\r'}"
		[ -z "${line}" ] && continue
		stamps+=("${line}")
	done

	[ "${#stamps[@]}" -eq 0 ] && return 0

	# newest first; the stamp format sorts lexicographically as it sorts
	# chronologically, which is the reason for choosing it
	mapfile -t stamps < <(printf '%s\n' "${stamps[@]}" | sort -ru)

	# One `date` invocation for the whole list rather than four per stamp:
	# GNU date reads dates from a file with -f, so 400 snapshots cost one fork.
	mapfile -t keys < <(
		for s in "${stamps[@]}"; do
			printf '%s-%s-%s %s:%s:%s\n' \
				"${s:0:4}" "${s:4:2}" "${s:6:2}" "${s:9:2}" "${s:11:2}" "${s:13:2}"
		done | date -f - '+%Y-%m-%d|%G-W%V|%Y-%m|%Y' 2>/dev/null
	)

	if [ "${#keys[@]}" -ne "${#stamps[@]}" ]; then
		log_err "retention: could not parse all snapshot timestamps (${#keys[@]} of ${#stamps[@]})"
		return 1
	fi

	local -a bucket_id=("" "" "" "")          # last bucket id kept, per type
	local -a bucket_left=("${keep_daily}" "${keep_weekly}" "${keep_monthly}" "${keep_yearly}")
	local -a type_name=("daily" "weekly" "monthly" "yearly")

	local i t id reasons rest
	for (( i = 0; i < ${#stamps[@]}; i++ )); do
		reasons=""
		rest="${keys[i]}"

		for (( t = 0; t < 4; t++ )); do
			id="${rest%%|*}"
			if [ "${t}" -lt 3 ]; then rest="${rest#*|}"; fi

			if [ "${bucket_left[t]}" -gt 0 ] && [ "${id}" != "${bucket_id[t]}" ]; then
				bucket_id[t]="${id}"
				bucket_left[t]=$(( bucket_left[t] - 1 ))
				reasons+="${reasons:+,}${type_name[t]}"
			fi
		done

		# hard floor: never let a policy discard the most recent snapshot
		if [ "${i}" -eq 0 ] && [ -z "${reasons}" ]; then
			reasons="newest"
		fi

		if [ -n "${reasons}" ]; then
			printf 'KEEP %s %s\n' "${stamps[i]}" "${reasons}"
		else
			printf 'DELETE %s\n' "${stamps[i]}"
		fi
	done

	return 0
}

# ---------------------------------------------------------------------------
# small helpers shared by the entry-point scripts
# ---------------------------------------------------------------------------

# parse_bool <value> <flag-name> - accepts true/false/yes/no/1/0, case-insensitive
parse_bool () {
	local v="${1,,}" name="$2"
	case "${v}" in
		true|yes|y|1|on)   printf 'true';  return 0 ;;
		false|no|n|0|off)  printf 'false'; return 0 ;;
		*) log_err "${name}: expected true or false, got '${1}'"; return 1 ;;
	esac
}

is_uint () { [[ "$1" =~ ^[0-9]+$ ]]; }

# is_keep_none <value> - is this keep value the mirror-only sentinel?
#
# "none" means "replicate this database but never snapshot it": a live mirror
# with no point-in-time history behind it. Note this is NOT the same as 0/0/0/0,
# which is refused - zero keeps would select every existing snapshot for
# deletion, whereas "none" never runs versioning at all and so never deletes.
is_keep_none () {
	case "${1,,}" in
		none) return 0 ;;
		*)    return 1 ;;
	esac
}

# parse_keep <value> [context]
#
# <context> is prefixed to every error, so the engine can say which inventory
# line a bad policy is on without this function needing to know what an
# inventory is.
#
# The whole retention policy is ONE inventory field:
#
#   7/5/12/7   keep 7 daily, 5 weekly, 12 monthly, 7 yearly
#   none       mirror-only: replicate the database, never snapshot it, and so
#              never prune it
#
# Sets CDB_KEEP_NONE and CDB_KEEP_D / _W / _M / _Y. Returns 1 with a specific
# reason on anything else.
#
# One field rather than four is not merely shorter to type. Split across four
# columns, 'none' in some of them but not others is writable and means nothing,
# so it needs a dedicated check and an error explaining a state that should not
# be reachable. Here 'none/5/12/7' is simply not four integers: not a rejected
# value, an unsayable one.
#
# 0/0/0/0 is refused: zero keeps would select every existing snapshot for
# deletion, which is never what the author meant. Write 'none' for that intent.
CDB_KEEP_NONE="false"
CDB_KEEP_D=""; CDB_KEEP_W=""; CDB_KEEP_M=""; CDB_KEEP_Y=""

parse_keep () {
	local value="$1"
	local ctx="${2:-}"
	local i
	local -a parts=()
	local -a names=(daily weekly monthly yearly)

	CDB_KEEP_NONE="false"
	CDB_KEEP_D=""; CDB_KEEP_W=""; CDB_KEEP_M=""; CDB_KEEP_Y=""

	if [ -z "${value}" ]; then
		log_err "${ctx}keep: empty; expected 'none' or daily/weekly/monthly/yearly, eg 7/5/12/7"
		return 1
	fi

	if is_keep_none "${value}"; then
		# shellcheck disable=SC2034  # part of this function's documented output
		CDB_KEEP_NONE="true"
		return 0
	fi

	IFS='/' read -r -a parts <<< "${value}"
	# Trim each part: this file is edited by hand, and '7 / 5 / 12 / 7' is a
	# reasonable thing to type.
	for i in "${!parts[@]}"; do
		parts[i]="${parts[i]#"${parts[i]%%[![:space:]]*}"}"
		parts[i]="${parts[i]%"${parts[i]##*[![:space:]]}"}"
	done

	if [ "${#parts[@]}" -ne 4 ]; then
		log_err "${ctx}keep: expected 'none' or four values daily/weekly/monthly/yearly, got '${value}' (${#parts[@]} value(s))"
		return 1
	fi

	for i in 0 1 2 3; do
		if ! is_uint "${parts[i]}"; then
			log_err "${ctx}keep: ${names[i]} must be a non-negative integer, got '${parts[i]}' in '${value}'"
			return 1
		fi
	done

	if [ "${parts[0]}" -eq 0 ] && [ "${parts[1]}" -eq 0 ] && [ "${parts[2]}" -eq 0 ] && [ "${parts[3]}" -eq 0 ]; then
		log_err "${ctx}keep: 0/0/0/0 would select every existing snapshot for deletion"
		log_err "${ctx}keep: to mirror a database without snapshotting it, write 'none'"
		return 1
	fi

	# shellcheck disable=SC2034  # the four below are this function's documented output
	CDB_KEEP_D="${parts[0]}"
	# shellcheck disable=SC2034
	CDB_KEEP_W="${parts[1]}"
	# shellcheck disable=SC2034
	CDB_KEEP_M="${parts[2]}"
	# shellcheck disable=SC2034
	CDB_KEEP_Y="${parts[3]}"
	return 0
}

# valid_db_name <name> - CouchDB's own rule for a creatable database name.
valid_db_name () {
	[[ "$1" =~ ^[a-z][a-z0-9_$()+/-]*$ ]]
}

# CDB_SNAP_SEP is the marker that separates a base database from its snapshot
# timestamp. Changing it would orphan every existing snapshot.
CDB_SNAP_SEP="_snap_"
CDB_SNAP_STAMP_RE='[0-9]{8}-[0-9]{6}'

snap_name () { printf '%s%s%s' "$1" "${CDB_SNAP_SEP}" "$2"; }

# is_snapshot_of <candidate> <base-db> - the single gate every delete goes
# through. Deliberately anchored and exact, so that a database merely sitting
# next to the base under some other naming scheme - db_day_3, db_week_34,
# db_month_08, db_2026, db_backup - can never match and can never be deleted.
is_snapshot_of () {
	local candidate="$1" base="$2"
	[[ "${candidate}" =~ ^"${base}""${CDB_SNAP_SEP}"${CDB_SNAP_STAMP_RE}$ ]]
}

# never_delete <name> - a belt-and-braces list of things that must survive any
# bug in the selection logic.
never_delete () {
	case "$1" in
		_users|_replicator|_global_changes|_metadata|_dbs|_nodes) return 0 ;;
		*) return 1 ;;
	esac
}
