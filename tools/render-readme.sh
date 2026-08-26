#!/bin/bash
#
# tools/render-readme.sh - regenerate README.html from README.md.
#
# script location /opt/couchdb-repv/tools/render-readme.sh
#
# README.html is a GENERATED file. Edit README.md and re-run this; an edit made
# directly to the HTML is lost the next time anyone renders.
#
# The output is self-contained - the CSS is inlined and nothing is fetched at
# view time - so it can be opened from a file:// path on a machine with no
# network, which is the case that matters when you are reading it to work out
# why last night's backup did not happen.
#
# usage:
#   tools/render-readme.sh           render README.md -> README.html
#   tools/render-readme.sh --check   is README.html current? no render, no pandoc
#
# --check compares the source hash stamped into README.html against README.md as
# it stands. It needs only sha256sum, deliberately: the staleness check has to
# work on a machine that cannot render, or it would quietly stop being run.
#
# exit codes: 0 ok, 1 stale or render failed, 2 usage error
#

set -uo pipefail

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${_here}/.." && pwd)"

SRC="${REPO}/README.md"
OUT="${REPO}/README.html"

# The stamp that ties the two files together. Changing this string orphans every
# existing README.html, which --check reports as stale - harmless, but re-render.
STAMP_PREFIX="source-sha256:"

MODE="render"
case "${1:-}" in
	"")        MODE="render" ;;
	--check)   MODE="check" ;;
	-h|--help)
		sed -n '3,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		echo "unknown argument: $1" >&2
		echo "usage: $(basename "$0") [--check]" >&2
		exit 2
		;;
esac

[ -f "${SRC}" ] || { echo "no README.md at ${SRC}" >&2; exit 1; }

src_hash () { sha256sum "${SRC}" | cut -d' ' -f1; }

# stamped_hash - the hash recorded in README.html, or empty if there is none.
stamped_hash () {
	[ -f "${OUT}" ] || return 0
	sed -n "s/.*${STAMP_PREFIX} \([0-9a-f]\{64\}\).*/\1/p" "${OUT}" | head -n1
}

# ---------------------------------------------------------------------------
# --check
# ---------------------------------------------------------------------------

if [ "${MODE}" = "check" ]; then
	if [ ! -f "${OUT}" ]; then
		echo "README.html does not exist - run tools/render-readme.sh" >&2
		exit 1
	fi
	want="$(src_hash)"
	have="$(stamped_hash)"
	if [ -z "${have}" ]; then
		echo "README.html carries no ${STAMP_PREFIX} stamp - run tools/render-readme.sh" >&2
		exit 1
	fi
	if [ "${have}" != "${want}" ]; then
		echo "README.html is STALE: it was rendered from a different README.md" >&2
		echo "  README.md   ${want}" >&2
		echo "  README.html ${have}" >&2
		echo "run tools/render-readme.sh and commit both files together" >&2
		exit 1
	fi
	echo "README.html is current (${want:0:12})"
	exit 0
fi

# ---------------------------------------------------------------------------
# render
# ---------------------------------------------------------------------------
#
# pandoc is the one renderer, not one of several. A fallback that produced
# different HTML would make README.html churn depending on who last touched it,
# and the diff would stop being reviewable.

if ! command -v pandoc >/dev/null 2>&1; then
	echo "pandoc is required to render README.html" >&2
	echo "  debian/ubuntu:  apt install pandoc" >&2
	echo "(tools/render-readme.sh --check still works without it)" >&2
	exit 1
fi

HASH="$(src_hash)"
TMPDIR_R="$(mktemp -d "${TMPDIR:-/tmp}/render-readme.XXXXXX")" || exit 1
trap 'rm -rf "${TMPDIR_R}"' EXIT

# The ONLY stylesheet on the page: pandoc's own is turned off with
# document-css=false above. Two stylesheets meant fighting a cascade for no
# gain - its default sets `table { display: block }`, which quietly beats a
# later `width: 100%` and leaves every table stopping short of the text.
#
# Inlined so the page needs nothing at view time. Light and dark are both
# defined explicitly: a page that defines only one borrows the other from the
# browser and ends up with black text on a black background.
cat > "${TMPDIR_R}/head.html" <<'HEAD'
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="generator" content="tools/render-readme.sh">
<style>
:root {
  color-scheme: light dark;
  --bg: #ffffff;      --fg: #1f2328;      --muted: #59636e;
  --border: #d1d9e0;  --code-bg: #f6f8fa; --link: #0969da;
  --quote-bar: #d1d9e0; --table-stripe: #f6f8fa; --mark: #fff8c5;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0d1117;    --fg: #e6edf3;      --muted: #9198a1;
    --border: #3d444d; --code-bg: #151b23; --link: #4493f8;
    --quote-bar: #3d444d; --table-stripe: #151b23; --mark: #4a3a00;
  }
}
* { box-sizing: border-box; }
body {
  background: var(--bg); color: var(--fg);
  font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
  margin: 0 auto; padding: 2rem 1.25rem 6rem; max-width: 56rem;
  overflow-wrap: break-word;
}
h1, h2, h3, h4 { line-height: 1.25; margin: 2em 0 .6em; font-weight: 600; }
h1 { font-size: 1.9rem; padding-bottom: .3em; border-bottom: 1px solid var(--border); margin-top: 0; }
h2 { font-size: 1.4rem; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
h3 { font-size: 1.15rem; }
h4 { font-size: 1rem; color: var(--muted); }
a { color: var(--link); text-decoration: none; }
a:hover { text-decoration: underline; }
p, ul, ol { margin: 0 0 1em; }
li { margin: .25em 0; }
hr { border: 0; border-top: 1px solid var(--border); margin: 2.5em 0; }
code {
  background: var(--code-bg); border-radius: 6px; padding: .15em .4em;
  font: .875em/1.5 ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
}
pre {
  background: var(--code-bg); border: 1px solid var(--border); border-radius: 6px;
  padding: 1em; overflow-x: auto; margin: 0 0 1em;
}
pre code { background: none; padding: 0; font-size: .8125rem; line-height: 1.5; }
blockquote {
  margin: 0 0 1em; padding: .1em 1em; color: var(--muted);
  border-left: .25em solid var(--quote-bar);
}
blockquote strong { color: var(--fg); }
img { max-width: 100%; }
/* Cell text wraps, so a table can never push the page sideways the way a <pre>
   can - which is why this one does not need its own scroll container. */
table { display: table; table-layout: auto; border-collapse: collapse; width: 100%; margin: 0 0 1em; font-size: .9375rem; }
th, td { border: 1px solid var(--border); padding: .45em .75em; text-align: left; vertical-align: top; }
th { background: var(--table-stripe); font-weight: 600; }
tr:nth-child(2n) td { background: var(--table-stripe); }
.table-scroll { overflow-x: auto; }
.generated-note {
  background: var(--mark); border: 1px solid var(--border); border-radius: 6px;
  padding: .6em .9em; margin: 0 0 2rem; font-size: .875rem; color: var(--fg);
}
.generated-note code { background: rgba(127,127,127,.18); }
</style>
HEAD

cat > "${TMPDIR_R}/before.html" <<'BEFORE'
<div class="generated-note">
This page is <strong>generated from <code>README.md</code></strong> by
<code>tools/render-readme.sh</code>. Edit the Markdown, not this file.
</div>
BEFORE

# Our own template rather than pandoc's default, which brings a stylesheet and
# an IE8 shim we do not want. -V document-css=false does NOT turn that
# stylesheet off: pandoc's $if()$ is true for any non-empty value, so the string
# "false" reads as true. Two stylesheets is not a cosmetic problem - the default
# sets `table { display: block }`, which quietly beats a later `width: 100%` and
# leaves every table stopping short of the text beside it.
cat > "${TMPDIR_R}/template.html" <<'TEMPLATE'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>$pagetitle$</title>
$for(header-includes)$
$header-includes$
$endfor$
</head>
<body>
$for(include-before)$
$include-before$
$endfor$
$body$
</body>
</html>
TEMPLATE

if ! pandoc \
	--from gfm \
	--to html5 \
	--standalone \
	--wrap=preserve \
	--template "${TMPDIR_R}/template.html" \
	--variable pagetitle="CouchDB replication and versioned backups" \
	--include-in-header "${TMPDIR_R}/head.html" \
	--include-before-body "${TMPDIR_R}/before.html" \
	--output "${TMPDIR_R}/out.html" \
	"${SRC}"
then
	echo "pandoc failed - README.html not written" >&2
	exit 1
fi

if grep -qE '(src|href)="(https?:)?//' "${TMPDIR_R}/out.html"; then
	echo "refusing to write ${OUT}: it references something off-machine" >&2
	grep -nE '(src|href)="(https?:)?//' "${TMPDIR_R}/out.html" >&2
	exit 1
fi

# Stamp the source hash so --check can tell current from stale without pandoc.
# Written after the doctype line so it survives any later reformatting.
{
	head -n1 "${TMPDIR_R}/out.html"
	printf '<!-- GENERATED by tools/render-readme.sh - do not edit. %s %s -->\n' \
		"${STAMP_PREFIX}" "${HASH}"
	tail -n +2 "${TMPDIR_R}/out.html"
} > "${OUT}" || { echo "cannot write ${OUT}" >&2; exit 1; }

printf 'rendered %s -> %s (%s %s)\n' \
	"$(basename "${SRC}")" "$(basename "${OUT}")" "${STAMP_PREFIX}" "${HASH:0:12}"
exit 0
