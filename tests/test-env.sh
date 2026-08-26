#!/bin/bash
#
# tests/test-env.sh - unit tests for env parsing, token expansion, URL handling
#                     and credential redaction. No CouchDB, no network.
#
# The theme: a password must survive parsing byte for byte, and must never
# appear in anything the scripts print or log.
#
# usage: tests/test-env.sh
#

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${_here}/.." && pwd)"

CDB_SYSLOG=false
export CDB_SYSLOG
# shellcheck source=couchdb-repv-common.sh
. "${REPO}/couchdb-repv-common.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cdb-test-env.XXXXXX")"
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

# write_env <name> <content...> - writes a 0600 env file, returns its path
write_env () {
	local name="$1"; shift
	local f="${TMP}/${name}"
	printf '%s' "$1" > "${f}"
	chmod 600 "${f}"
	printf '%s' "${f}"
}

reset_secrets () { CDB_SECRET=(); }

echo "== env_load =="

# --- keys that are not valid shell identifiers -----------------------------
#
# This is the whole reason the file is parsed rather than sourced: a key like
# couchdb.example.com_USER cannot be a shell variable name.

F="$(write_env basic '192.168.66.30_USER=admin
192.168.66.30_PASS=fixture-pw-1
couchdb.example.com_USER=root
couchdb.example.com_PASS=s3cret
')"
reset_secrets
env_load "${F}" >/dev/null 2>&1
assert_eq "an IP key loads"                 "admin"    "${CDB_SECRET[192.168.66.30_USER]:-}"
assert_eq "an IP key's password loads"      "fixture-pw-1" "${CDB_SECRET[192.168.66.30_PASS]:-}"
assert_eq "a dotted FQDN key loads"         "root"     "${CDB_SECRET[couchdb.example.com_USER]:-}"
assert_eq "a dotted FQDN password loads"    "s3cret"   "${CDB_SECRET[couchdb.example.com_PASS]:-}"

# Sourcing this file would be a syntax error - proving the parser is required.
assert_eq "the env file is genuinely not sourceable" \
	"nonzero" \
	"$(bash -c ". '${F}'" >/dev/null 2>&1 && echo zero || echo nonzero)"

# --- comments, blanks, CRLF, export ----------------------------------------

F="$(write_env messy '# a comment
   # an indented comment

  192.168.66.30_USER=admin

export 192.168.66.30_PASS=fixture-pw-1
')"
reset_secrets
env_load "${F}" >/dev/null 2>&1
assert_eq "comments and blank lines are skipped" "admin"     "${CDB_SECRET[192.168.66.30_USER]:-}"
assert_eq "an export prefix is accepted"         "fixture-pw-1" "${CDB_SECRET[192.168.66.30_PASS]:-}"

printf '192.168.66.30_USER=admin\r\n192.168.66.30_PASS=fixture-pw-1\r\n' > "${TMP}/crlf"
chmod 600 "${TMP}/crlf"
reset_secrets
env_load "${TMP}/crlf" >/dev/null 2>&1
assert_eq "a CRLF file does not leave \\r on the value" "fixture-pw-1" "${CDB_SECRET[192.168.66.30_PASS]:-}"

# --- awkward password characters -------------------------------------------
#
# Values are taken verbatim after one optional layer of matching quotes. A
# password containing = # $ { } or spaces must round-trip exactly.

F="$(write_env awkward '192.168.66.30_PASS=a=b#c$d{e}f
192.168.66.31_PASS="quoted value"
192.168.66.32_PASS='"'"'single quoted'"'"'
192.168.66.33_PASS=
192.168.66.34_PASS=trailing spaces   
')"
reset_secrets
env_load "${F}" >/dev/null 2>&1
assert_eq "= # \$ { } survive verbatim"        'a=b#c$d{e}f'    "${CDB_SECRET[192.168.66.30_PASS]:-}"
assert_eq "double quotes are stripped once"    'quoted value'   "${CDB_SECRET[192.168.66.31_PASS]:-}"
assert_eq "single quotes are stripped once"    'single quoted'  "${CDB_SECRET[192.168.66.32_PASS]:-}"
assert_eq "an empty value is preserved"        ''               "${CDB_SECRET[192.168.66.33_PASS]:-}"
assert_eq "trailing spaces are preserved"      'trailing spaces   ' "${CDB_SECRET[192.168.66.34_PASS]:-}"

# --- file permissions ------------------------------------------------------

F="$(write_env perms '192.168.66.30_USER=admin
192.168.66.30_PASS=fixture-pw-1
')"
chmod 644 "${F}"
reset_secrets
assert_eq "a group/other-readable env file is refused" \
	"1" "$(env_load "${F}" >/dev/null 2>&1; echo $?)"
reset_secrets
assert_eq "--allow-insecure-env overrides that" \
	"0" "$(env_load "${F}" true >/dev/null 2>&1; echo $?)"
chmod 600 "${F}"
reset_secrets
assert_eq "a 0600 env file is accepted" \
	"0" "$(env_load "${F}" >/dev/null 2>&1; echo $?)"

assert_eq "a missing env file is an error" \
	"1" "$(env_load "${TMP}/does-not-exist" >/dev/null 2>&1; echo $?)"

F="$(write_env empty '# nothing but comments
')"
reset_secrets
assert_eq "an env file with no entries is an error" \
	"1" "$(env_load "${F}" >/dev/null 2>&1; echo $?)"

echo
echo "== redaction =="

assert_eq "credentials in a URL are redacted" \
	"http://***:***@192.168.66.30:5984/db" \
	"$(redact 'http://admin:fixture-pw-1@192.168.66.30:5984/db')"

assert_eq "every URL on a line is redacted, not just the first" \
	"replicate http://***:***@a:5984/x -> https://***:***@b:6984/x" \
	"$(redact 'replicate http://admin:pw1@a:5984/x -> https://root:pw2@b:6984/x')"

assert_eq "a URL with no credentials is left alone" \
	"http://192.168.66.30:5984/db" \
	"$(redact 'http://192.168.66.30:5984/db')"

assert_eq "text without a URL is left alone" \
	"nothing to redact here" \
	"$(redact 'nothing to redact here')"

# The direct assertion: run the logger over a message containing a real
# password and prove the password is not in the output.
SECRET_PW='sup3r-s3cret-pw'
LOGGED="$(log "replicating http://admin:${SECRET_PW}@192.168.66.30:5984/acme" 2>&1)"
assert_eq "log() output does not contain the password" \
	"absent" \
	"$(printf '%s' "${LOGGED}" | grep -q "${SECRET_PW}" && echo "LEAKED" || echo "absent")"
assert_eq "log() output still contains the host" \
	"present" \
	"$(printf '%s' "${LOGGED}" | grep -q '192.168.66.30:5984/acme' && echo "present" || echo "missing")"

LOGGED="$(log_err "failed http://admin:${SECRET_PW}@h:5984" 2>&1)"
assert_eq "log_err() output does not contain the password" \
	"absent" \
	"$(printf '%s' "${LOGGED}" | grep -q "${SECRET_PW}" && echo "LEAKED" || echo "absent")"

echo
echo "== URL handling =="

assert_eq "normalise_url keeps a plain URL"  "http://h:5984" "$(normalise_url 'http://h:5984')"
assert_eq "normalise_url drops a trailing /" "http://h:5984" "$(normalise_url 'http://h:5984/')"
assert_eq "normalise_url percent-encodes credentials" \
	"http://ad%40min:p%40ss%3Aw%2Frd@h:5984" \
	"$(normalise_url 'http://ad@min:p@ss:w/rd@h:5984')"
assert_eq "normalise_url accepts https" "https://h:6984" "$(normalise_url 'https://h:6984')"
assert_eq "normalise_url rejects a non-http scheme" \
	"1" "$(normalise_url 'ftp://h:5984' >/dev/null 2>&1; echo $?)"
assert_eq "normalise_url rejects a URL with a path" \
	"1" "$(normalise_url 'http://h:5984/somedb' >/dev/null 2>&1; echo $?)"
assert_eq "normalise_url rejects an empty string" \
	"1" "$(normalise_url '' >/dev/null 2>&1; echo $?)"

assert_eq "normalise_url handles a password containing @" \
	"http://admin:p%40ss@h:5984" \
	"$(normalise_url 'http://admin:p@ss@h:5984')"
assert_eq "a password containing @ does not corrupt the host" \
	"h:5984" \
	"$(host_of 'http://admin:p@ss@h:5984')"

assert_eq "host_of strips credentials" "192.168.66.30:5984" "$(host_of 'http://admin:pw@192.168.66.30:5984')"
assert_eq "host_of works without credentials" "h:5984" "$(host_of 'http://h:5984')"

echo
echo "== parse_bool =="

assert_eq "parse_bool true"  "true"  "$(parse_bool true --x)"
assert_eq "parse_bool TRUE"  "true"  "$(parse_bool TRUE --x)"
assert_eq "parse_bool yes"   "true"  "$(parse_bool yes --x)"
assert_eq "parse_bool 1"     "true"  "$(parse_bool 1 --x)"
assert_eq "parse_bool false" "false" "$(parse_bool false --x)"
assert_eq "parse_bool 0"     "false" "$(parse_bool 0 --x)"
assert_eq "parse_bool rejects nonsense" "1" "$(parse_bool banana --x >/dev/null 2>&1; echo $?)"

echo
echo "== json helpers =="

BODY='{"ok":true,"session_id":"abc","docs_read":12,"docs_written":12,"doc_write_failures":0}'
assert_eq "json_field reads a boolean" "true" "$(json_field "${BODY}" ok)"
assert_eq "json_field reads a string"  "abc"  "$(json_field "${BODY}" session_id)"
assert_eq "json_field reads a number"  "12"   "$(json_field "${BODY}" docs_read)"
assert_eq "json_field reads a zero"    "0"    "$(json_field "${BODY}" doc_write_failures)"
assert_eq "json_field misses cleanly"  "1"    "$(json_field "${BODY}" nope >/dev/null 2>&1; echo $?)"

# doc_write_failures must not be confused with docs_written by a prefix match
assert_eq "json_field does not prefix-match another key" \
	"12" "$(json_field '{"docs_written":12,"doc_write_failures":3}' docs_written)"

assert_eq "json_array_of_strings splits _all_dbs" \
	"_replicator _users acme acme_snap_20260825-020500" \
	"$(json_array_of_strings '["_replicator","_users","acme","acme_snap_20260825-020500"]' | tr '\n' ' ' | sed 's/ $//')"

assert_eq "json_array_of_strings handles an empty list" \
	"" \
	"$(json_array_of_strings '[]' | tr '\n' ' ' | sed 's/ $//')"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
