#!/bin/bash
#
# tests/test-inventory.sh - unit tests for the servers alias table, server
#                           resolution and the 'keep' policy column.
#                           No CouchDB, no network.
#
# The theme: an inventory row says 'bak1', not a credentialled URL, so the code
# that turns 'bak1' into that URL is the code that decides which machine gets
# written to. It is tested here in the same spirit as retention_select: the
# functions that can do damage are written so they can be exercised with no
# CouchDB in the way.
#
# usage: tests/test-inventory.sh
#

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${_here}/.." && pwd)"

CDB_SYSLOG=false
export CDB_SYSLOG
# shellcheck source=couchdb-repv-common.sh
. "${REPO}/couchdb-repv-common.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cdb-test-inv.XXXXXX")"
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

# assert_rc <label> <expected-rc> <command...>
assert_rc () {
	local label="$1" want="$2"; shift 2
	local got=0
	"$@" >/dev/null 2>&1 || got=$?
	assert_eq "${label}" "${want}" "${got}"
}

# write_file <name> <content> - returns its path
write_file () {
	local f="${TMP}/$1"
	printf '%s' "$2" > "${f}"
	printf '%s' "${f}"
}

# write_env <name> <content> - a 0600 env file, as env_load insists on
write_env () {
	local f
	f="$(write_file "$1" "$2")"
	chmod 600 "${f}"
	printf '%s' "${f}"
}

reset_servers () { CDB_SERVER=(); CDB_SERVER_ALIAS=(); }
reset_secrets () { CDB_SECRET=(); }

# The standard fixture: three aliases, no credentials in the table.
SERVERS_OK="$(write_file servers-ok.csv 'alias,url
bak1,http://192.168.66.5:5984
bak2,http://192.168.66.11:5984
cloud,http://203.0.113.10:5984
')"

ENV_OK="$(write_env env-ok '192.168.66.5_USER=admin
192.168.66.5_PASS=s3cret
192.168.66.11_USER=admin
192.168.66.11_PASS=other-pw
203.0.113.10_USER=cloudadmin
203.0.113.10_PASS=cloud-pw
')"

echo "== servers_load =="

reset_servers
assert_rc "a well-formed servers file loads" 0 servers_load "${SERVERS_OK}"
assert_eq "every alias is recorded" "3" "${#CDB_SERVER[@]}"
assert_eq "an alias maps to its url" "http://192.168.66.5:5984" "${CDB_SERVER[bak1]}"
assert_eq "servers_known lists them sorted" "bak1 bak2 cloud" "$(servers_known)"

# --- header is authoritative, order is free --------------------------------
reset_servers
F="$(write_file servers-reordered.csv 'url,alias
http://192.168.66.5:5984,bak1
')"
assert_rc "column order is free" 0 servers_load "${F}"
assert_eq "reordered columns still map correctly" "http://192.168.66.5:5984" "${CDB_SERVER[bak1]}"

reset_servers
F="$(write_file servers-nocol.csv 'name,url
bak1,http://192.168.66.5:5984
')"
assert_rc "a renamed column is a startup error, not a shifted field" 1 servers_load "${F}"

reset_servers
F="$(write_file servers-noheader.csv '# nothing but a comment
')"
assert_rc "a file with no header row is rejected" 1 servers_load "${F}"

reset_servers
F="$(write_file servers-empty.csv 'alias,url
')"
assert_rc "a header with no aliases under it is rejected" 1 servers_load "${F}"

assert_rc "a missing servers file is an error" 1 servers_load "${TMP}/does-not-exist.csv"

# --- blanks, comments, CRLF ------------------------------------------------
reset_servers
F="$(write_file servers-noise.csv 'alias,url

# the LAN backup node
bak1,http://192.168.66.5:5984

  # indented comment
  bak2 , http://192.168.66.11:5984
')"
assert_rc "blank lines, comments and stray spaces are tolerated" 0 servers_load "${F}"
assert_eq "whitespace around fields is trimmed" "http://192.168.66.11:5984" "${CDB_SERVER[bak2]}"

reset_servers
F="$(write_file servers-crlf.csv 'alias,url
bak1,http://192.168.66.5:5984
')"
sed -i 's/$/\r/' "${F}"
assert_rc "a CRLF file loads" 0 servers_load "${F}"
assert_eq "the CR is not part of the url" "http://192.168.66.5:5984" "${CDB_SERVER[bak1]}"

# --- rejections ------------------------------------------------------------
#
# Every one of these refuses the WHOLE file. A half-understood server table is
# not something to run a backup job against: the rows that did parse would
# still write to real machines.

reset_servers
F="$(write_file servers-dup.csv 'alias,url
bak1,http://192.168.66.5:5984
bak1,http://192.168.66.99:5984
')"
assert_rc "a duplicate alias is refused rather than last-wins" 1 servers_load "${F}"

reset_servers
F="$(write_file servers-badalias.csv 'alias,url
lan 5,http://192.168.66.5:5984
')"
assert_rc "an alias with a space is refused" 1 servers_load "${F}"

reset_servers
F="$(write_file servers-colonalias.csv 'alias,url
http://x,http://192.168.66.5:5984
')"
assert_rc "an alias that looks like a URL is refused" 1 servers_load "${F}"

reset_servers
F="$(write_file servers-badurl.csv 'alias,url
bak1,192.168.66.5:5984
')"
assert_rc "a url with no scheme is refused" 1 servers_load "${F}"

reset_servers
F="$(write_file servers-pathurl.csv 'alias,url
bak1,http://192.168.66.5:5984/somedb
')"
assert_rc "a url with a path is refused" 1 servers_load "${F}"

reset_servers
F="$(write_file servers-emptyurl.csv 'alias,url
bak1,
')"
assert_rc "an empty url is refused" 1 servers_load "${F}"

reset_servers
F="$(write_file servers-short.csv 'alias,url
bak1
')"
assert_rc "a row with too few fields is refused" 1 servers_load "${F}"

# --- credentials in the table are refused ----------------------------------
#
# The env file is the only source of credentials. A second one would mean two
# places to look when a password stops working, and would put a secret in the
# one config file that is meant to be committed.
reset_servers
F="$(write_file servers-creds.csv 'alias,url
bak1,http://admin:s3cret@192.168.66.5:5984
')"
out="$(servers_load "${F}" 2>&1)"
assert_rc "an inline-credential url is refused" 1 servers_load "${F}"
case "${out}" in
	*"put them in the --env file"*) ok "and the error says where they belong" ;;
	*) no "and the error says where they belong"; printf '       output: [%s]\n' "${out}" ;;
esac
case "${out}" in
	*s3cret*) no "the error does not leak the password" ;;
	*)        ok "the error does not leak the password" ;;
esac

echo
echo "== resolve_server =="

reset_servers; reset_secrets
servers_load "${SERVERS_OK}" >/dev/null 2>&1
env_load "${ENV_OK}" >/dev/null 2>&1

assert_eq "an alias resolves to a credentialled url" \
	"http://admin:s3cret@192.168.66.5:5984" "$(resolve_server bak1)"
assert_eq "each alias gets its own host's credentials" \
	"http://cloudadmin:cloud-pw@203.0.113.10:5984" "$(resolve_server cloud)"

# --- an alias is the ONLY form ---------------------------------------------
#
# There is no '://' discriminator. A URL in a server column is not a URL, it is
# an alias nobody defined - which is what the error has to say, so that pasting
# a spelled-out row in produces an explanation rather than a mystery.

assert_rc "a literal url is not a server field" 1 resolve_server 'http://admin:pw@192.168.66.5:5984'
assert_rc "a \${...} token is not a server field" 1 \
	resolve_server 'http://${192.168.66.5_USER}:${192.168.66.5_PASS}@192.168.66.5:5984'

out="$(resolve_server 'http://192.168.66.5:5984' 2>&1)"
case "${out}" in
	*"unknown server alias"*) ok "a pasted URL is reported as an unknown alias" ;;
	*) no "a pasted URL is reported as an unknown alias"; printf '       output: [%s]\n' "${out}" ;;
esac

reset_servers
servers_load "$(write_file servers-slash.csv 'alias,url
bak1,http://192.168.66.5:5984/
')" >/dev/null 2>&1
assert_eq "a trailing slash in the table is dropped" \
	"http://admin:s3cret@192.168.66.5:5984" "$(resolve_server bak1)"

reset_servers
servers_load "${SERVERS_OK}" >/dev/null 2>&1

# --- alias failures --------------------------------------------------------
assert_rc "an unknown alias is a hard error" 1 resolve_server nosuch
assert_rc "an empty server field is a hard error" 1 resolve_server ""

out="$(resolve_server nosuch 2>&1)"
case "${out}" in
	*"bak1 bak2 cloud"*) ok "the unknown-alias error names the aliases that do exist" ;;
	*) no "the unknown-alias error names the aliases that do exist"; printf '       output: [%s]\n' "${out}" ;;
esac

reset_servers
out="$(resolve_server bak1 2>&1)"
case "${out}" in
	*--servers*) ok "with no table loaded, the error points at --servers" ;;
	*) no "with no table loaded, the error points at --servers"; printf '       output: [%s]\n' "${out}" ;;
esac

# --- credential derivation -------------------------------------------------

reset_servers; reset_secrets
servers_load "${SERVERS_OK}" >/dev/null 2>&1
env_load "$(write_env env-partial '192.168.66.5_USER=admin
')" >/dev/null 2>&1
assert_rc "a _USER with no _PASS is refused" 1 resolve_server bak1

reset_secrets
env_load "$(write_env env-none '192.168.66.99_USER=admin
192.168.66.99_PASS=pw
')" >/dev/null 2>&1
assert_rc "an alias with no env entry at all is refused" 1 resolve_server bak1
out="$(resolve_server bak1 2>&1)"
case "${out}" in
	*192.168.66.5_USER*192.168.66.5_PASS*) ok "the missing-credential error names the exact env keys to add" ;;
	*) no "the missing-credential error names the exact env keys to add"; printf '       output: [%s]\n' "${out}" ;;
esac

# The port-qualified key wins, so two CouchDBs on one box can differ.
reset_servers; reset_secrets
servers_load "$(write_file servers-twoports.csv 'alias,url
a,http://192.168.66.7:5984
b,http://192.168.66.7:6984
')" >/dev/null 2>&1
env_load "$(write_env env-ports '192.168.66.7_USER=plain
192.168.66.7_PASS=plain-pw
192.168.66.7:6984_USER=ported
192.168.66.7:6984_PASS=ported-pw
')" >/dev/null 2>&1
assert_eq "host:port credentials win where they exist" \
	"http://ported:ported-pw@192.168.66.7:6984" "$(resolve_server b)"
assert_eq "the bare host key is the fallback" \
	"http://plain:plain-pw@192.168.66.7:5984" "$(resolve_server a)"

# A password with URL-significant characters must survive to the wire.
reset_servers; reset_secrets
servers_load "${SERVERS_OK}" >/dev/null 2>&1
env_load "$(write_env env-awkward '192.168.66.5_USER=admin
192.168.66.5_PASS=p@ss:w/rd#1
')" >/dev/null 2>&1
assert_eq "an awkward password is percent-encoded into the url" \
	"http://admin:p%40ss%3Aw%2Frd%231@192.168.66.5:5984" "$(resolve_server bak1)"

# A password is carried from the env file into a URL here, so this is where the
# no-shell-re-entry property now has to hold. Moved from the expand_tokens tests
# when that function was removed: the property outlived the code that had it.
reset_servers; reset_secrets
servers_load "${SERVERS_OK}" >/dev/null 2>&1
env_load "$(write_env env-evil '192.168.66.5_USER=admin
192.168.66.5_PASS=$(touch '"${TMP}"'/pwned)`touch '"${TMP}"'/pwned2`
')" >/dev/null 2>&1
resolve_server bak1 >/dev/null 2>&1
assert_eq "a command-substitution payload in a password is not executed" "nofiles" \
	"$( { [ -e "${TMP}/pwned" ] || [ -e "${TMP}/pwned2" ]; } && echo "EXECUTED" || echo "nofiles" )"

reset_servers; reset_secrets
servers_load "${SERVERS_OK}" >/dev/null 2>&1
env_load "$(write_env env-awkward2 '192.168.66.5_USER=admin
192.168.66.5_PASS=p@ss:w/rd#1
')" >/dev/null 2>&1
out="$(resolve_server bak1 2>&1 >/dev/null; log "resolved $(resolve_server bak1)" 2>&1)"
case "${out}" in
	*'***:***@192.168.66.5:5984'*) ok "a resolved url is redacted when logged" ;;
	*) no "a resolved url is redacted when logged"; printf '       output: [%s]\n' "${out}" ;;
esac

echo
echo "== server_label =="

reset_servers
servers_load "${SERVERS_OK}" >/dev/null 2>&1
assert_eq "a known host labels as its alias" "bak1" "$(server_label 'http://admin:pw@192.168.66.5:5984')"
assert_eq "an unknown host labels as host:port" "10.0.0.1:5984" "$(server_label 'http://admin:pw@10.0.0.1:5984')"

reset_servers
F="$(write_file servers-twonames.csv 'alias,url
bak1,http://192.168.66.5:5984
rep1,http://192.168.66.5:5984
')"
servers_load "${F}" >/dev/null 2>&1
assert_eq "two aliases for one box are both usable" \
	"$(resolve_server bak1)" "$(resolve_server rep1)"
assert_eq "the label is the first alias, so it does not depend on the row" \
	"bak1" "$(server_label 'http://192.168.66.5:5984')"

echo
echo "== parse_keep =="

assert_rc "a four-value policy parses" 0 parse_keep 7/5/12/7
parse_keep 7/5/12/7
assert_eq "daily is read"   "7"  "${CDB_KEEP_D}"
assert_eq "weekly is read"  "5"  "${CDB_KEEP_W}"
assert_eq "monthly is read" "12" "${CDB_KEEP_M}"
assert_eq "yearly is read"  "7"  "${CDB_KEEP_Y}"
assert_eq "it is not the mirror-only sentinel" "false" "${CDB_KEEP_NONE}"

parse_keep none
assert_eq "'none' sets the mirror-only sentinel" "true" "${CDB_KEEP_NONE}"
parse_keep NONE
assert_eq "'none' is case-insensitive, as a hand-edited CSV needs" "true" "${CDB_KEEP_NONE}"

parse_keep ' 7 / 5 / 12 / 7 '
assert_eq "spaces around the values are trimmed" "12" "${CDB_KEEP_M}"

parse_keep 0/0/0/1
assert_eq "zeros are fine as long as one keep is non-zero" "0" "${CDB_KEEP_D}"

# --- the half-sentinel that cannot be written down -------------------------
#
# Split across four columns, 'none,5,12,7' is writable, meaningless, and needs a
# dedicated check and a two-line error. In one field it is not a rejected value
# but an unsayable one: it simply is not four integers.
assert_rc "a half sentinel is not expressible" 1 parse_keep none/5/12/7

assert_rc "0/0/0/0 stays refused" 1 parse_keep 0/0/0/0
out="$(parse_keep 0/0/0/0 2>&1)"
case "${out}" in
	*"write 'none'"*) ok "the 0/0/0/0 error says what to write instead" ;;
	*) no "the 0/0/0/0 error says what to write instead"; printf '       output: [%s]\n' "${out}" ;;
esac

assert_rc "three values are refused" 1 parse_keep 7/5/12
assert_rc "five values are refused" 1 parse_keep 7/5/12/7/3
assert_rc "an empty slot is refused" 1 parse_keep '7//12/7'
assert_rc "a negative keep is refused" 1 parse_keep '7/-1/12/7'
assert_rc "a non-numeric keep is refused" 1 parse_keep '7/five/12/7'
assert_rc "an empty policy is refused" 1 parse_keep ''
assert_rc "a comma-separated policy is not silently accepted" 1 parse_keep '7,5,12,7'

# The context argument is how the engine names the offending inventory line
# without parse_keep having to know what an inventory is.
out="$(parse_keep 7/5/12 'inventory line 9: ' 2>&1)"
case "${out}" in
	*"inventory line 9: keep:"*) ok "the context argument prefixes the error" ;;
	*) no "the context argument prefixes the error"; printf '       output: [%s]\n' "${out}" ;;
esac

# A failed parse must not leave the previous row's numbers behind: that is how
# a policy gets applied to the wrong database.
parse_keep 7/5/12/7
parse_keep bogus 2>/dev/null
assert_eq "a failed parse clears the previous values" "" "${CDB_KEEP_D}"
assert_eq "a failed parse clears the sentinel too" "false" "${CDB_KEEP_NONE}"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
