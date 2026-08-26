# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`couchdb-repv.sh` and its components — a config-driven CouchDB replicator that mirrors databases
between servers and keeps restic-style pruned snapshots on the target. It is tied to no particular
fleet: what to replicate, what the server aliases mean, and what the passwords are all live in three
CSV/env files passed on the command line.

```
couchdb-repv.sh \
    --inventory /root/couchdb-repv/repv-inventory.csv \
    --servers   /root/couchdb-repv/repv-servers.csv \
    --env       /root/couchdb-repv/.repv-env \
    --dry-run
```

**This repository is public.** Everything in it is read by strangers, and everything committed to it
is permanent. See [Hard rules](#hard-rules).

Running the entry point fires real replications against whatever the config names — never execute it
to "test" a change. Use `--check` (no network at all) or `--dry-run`.

---

## Hard rules

### 1. Tests need credentials the user supplies

The integration suite talks to live CouchDB servers. It has **no default host, no bundled fixture and
no fallback**: it reads a servers table and an env file the user writes, and exits 1 naming the
missing file if either is absent.

```
.repv-test-servers.csv    aliases test0 (source) and test1 (target)   [CDB_TEST_SERVERS]
.repv-test-env            <host>_USER / <host>_PASS, chmod 600        [CDB_TEST_ENV]
.repv-test-inventory.csv  for the manual smoke run only               [not read by the suite]
```

Do not invent test hosts, do not hardcode one "just to check", and do not add a default that points
anywhere. If a change needs a live server to verify, say so and stop — the user decides which servers
get written to. `tests/run-all.sh --unit` is the offline suite and must stay runnable with no config
at all.

### 2. Only `*.example` configuration files are committed

A real inventory names real databases, a real servers table names real machines, and a real env file
holds real passwords. None of the three is committable. The `.example` files are the documentation
for their formats and are the only config in git.

### 3. Nothing private, infrastructural or historical goes in

Never commit, and never write into a file, comment, test fixture or commit message:

- real hostnames, domains, IP addresses or ports of any actual deployment
- real database names, client names, company names, or user account names
- credentials of any kind, including "obviously fake" ones next to a real host
- local filesystem paths from a developer's machine (a home directory, a personal mount point)
- descriptions of, or comparisons to, any predecessor tooling, private repo, or existing fleet —
  including "the old scripts did X", variable names from them, and migration runbooks

Where documentation needs an address, use `192.168.66.x` for a LAN host, `203.0.113.x` (TEST-NET-3,
reserved for documentation) for anything public-facing, and `example.com` for a domain. The `.66`
subnet is deliberate: `192.168.0.x` and `192.168.1.x` are the two most common real home and office
LANs, so an example copied out of here verbatim would be pointing at somebody's actual gateway.
Where it needs a database name, use a generic one (`orders`, `app_meta`, `ledger_test`).

Rationale that would otherwise reference an old tool should be rewritten to stand on its own — say
*why the behaviour is right*, not *what it replaced*. Before committing, grep the diff for the
patterns above.

---

## The tool

Config is split three ways **by audience, not by convenience**: the inventory says what to replicate,
the servers table says what its aliases mean and holds no secrets (so it is committable and a
topology change is reviewable in `git log`), and the env file holds the passwords at `0600`. All
three are required and none is inferred.

One invocation per job, everything explicit. `--log-tag` is what keeps two jobs apart in syslog:

```
5 2 * * * /opt/couchdb-repv/couchdb-repv.sh --log-tag repv \
    --inventory /root/couchdb-repv/repv-inventory.csv \
    --servers /root/couchdb-repv/repv-servers.csv \
    --env /root/couchdb-repv/.repv-env
```

| file | role |
|---|---|
| `couchdb-repv.sh` | **the entry point** — read inventory + servers + env, preflight, drive the two components |
| `couchdb-repv-version.sh` | versioning component: snapshot one database, prune to the keep policy |
| `couchdb-repv-replicate.sh` | replicate component: copy one database src → targ |
| `couchdb-repv-common.sh` | sourced library: logging, env parsing, redaction, `couch_req`, `retention_select`, `servers_load`/`resolve_server`, `parse_keep` |

**These four are one program.** Deploy the whole directory, not a single file — every script sources
`couchdb-repv-common.sh` from its own directory, and the entry point runs the other two as children.
A fix goes in one place.

### Servers table

```
alias,url
bak1,http://192.168.66.5:5984
cloud,http://203.0.113.10:5984
```

Named by `--servers`, which is required. Holds no credentials **by design**: those come from the env
file, keyed by the hostname the alias resolves to, so renaming an alias never touches the secrets
file. A url here carrying credentials is **refused**, not warned about — a second source of passwords
means two places to look when one stops working, and puts a secret in the one config file meant to be
committed.

Aliases are named after the **box**, not the role: the same machine is `targ-svr` on one row and
`rep-svr` on another, and role-prefixed names would force it to appear twice and drift.

A duplicate alias is an error rather than last-wins, and **any bad entry refuses the whole file** —
unlike a bad inventory row, which is dropped and named, because the entries that did parse would
still write to real machines.

Every run logs the mapping once (`servers: bak1 -> 192.168.66.5:5984, ...`) and every other line names
servers by alias. It logs `host:port`, never the url: the mapping must not be one redaction bug away
from putting a password in syslog.

### Inventory CSV

The header row is authoritative — column order is free, but a missing column is a startup error
rather than a silently shifted field. Blank lines and `#` lines are skipped, and every row's field
count is checked against the header. There is no quoting: neither a CouchDB database name nor an
alias can contain a comma.

```
src-svr,targ-svr,rep-svr,db-name,keep
cloud,bak1,bak1,orders,7/5/12/7
cloud,bak1,bak1,orders_test,none
```

`keep` is `daily/weekly/monthly/yearly` or `none`. `none` is mirror-only: replicate this database but
never snapshot it, so `couchdb-repv-version.sh` is not invoked for that row at all — switching a
database to mirror-only strands its existing snapshots rather than deleting them. `0/0/0/0` stays
refused, because zero keeps would select every snapshot for deletion. `none/5/12/7` is not four
integers and so is simply unsayable.

**Every server column is an alias, and only an alias.** An inventory never holds a URL and never
holds a credential; a URL in a server column is read as an alias nobody defined, and the error says
so. There is one accepted form, deliberately: a parser with two has to explain both.

`rep-svr` is the node whose `/_replicate` performs the copy, and it must reach **both** src and targ.
Usually that is the target, which pulls — but a cloud node cannot reach a `192.168.x` source, so for
those rows it has to be the LAN node. That is why `rep-svr` is per row rather than global, and with
aliases the rule is visible on the line: `bak2,cloud,bak1` reads as "from bak2 to cloud, driven by
bak1".

### `--check`

Resolves inventory + servers + env, prints the resulting table and the servers behind it, and stops.
**No run lock, no network, no writes**, so it is safe while a run is going. The alias table adds a hop
between what the file says and which machine gets written to; this is where that hop is made visible.
Exit 0 usable, 1 rows rejected, 2 header error.

It says nothing about whether the servers are *up*: a resolved `http://***:***@host` means credentials
were found, not that they work. That is preflight's job.

### Env file

```
couchdb.example.com_USER=admin
couchdb.example.com_PASS=CHANGE_ME
203.0.113.10_USER=admin
203.0.113.10_PASS=CHANGE_ME
```

Keys are hostnames, so they contain dots and **are not valid shell identifiers**: this file can never
be `source`d. It is parsed line by line into an associative array and `${...}` tokens are substituted
by string slicing — no `eval`, no subshell, so a `$(...)` in a password stays literal text. The
scripts **refuse an env file that is group- or other-readable** (`--allow-insecure-env` overrides).

Keys are the **hostname, never the alias**. A key may be port-qualified
(`192.168.66.7:6984_USER`) and that form wins over the bare hostname, for two CouchDBs sharing a box.

Every log line goes through `redact()`, so `http://user:pass@host` becomes `http://***:***@host`. No
credential ever reaches the screen or syslog.

### Versioning: restic-style, and it DELETES

`couchdb-repv-version.sh` takes a target-to-target copy named `<db>_snap_<YYYYMMDD-HHMMSS>`, then
deletes every snapshot outside the keep policy — the same selection `restic forget` makes. Walking
newest to oldest, a snapshot is kept when it *opens a new bucket* of a type that still has keeps left;
buckets are `%Y-%m-%d`, **`%G-W%V`** (ISO year+week — `%Y-%V` would merge 2025-12-31 into the wrong
year), `%Y-%m` and `%Y`. So these are the last N snapshots that open a new day/week/month/year, not
the last N calendar days: gaps do not consume keeps. `7/5/12/7` tops out at ~31 copies per database.

Several runs in one day collapse to one snapshot, so a mid-day re-run is safe.

Nothing is deleted unless every one of these holds:

- a new snapshot was created **and verified** (http 200, `ok:true`, `doc_write_failures:0`, and its
  `doc_count` matches the base database). No good new snapshot means no deletions at all.
- the name matches `^<db>_snap_[0-9]{8}-[0-9]{6}$` — which is why a database named by any other
  scheme sitting beside the base (`db_day_3`, `db_backup`) can never be caught up in a prune
- it is not the base database, the snapshot just taken, or a `_users`/`_replicator`-style system db
- the newest snapshot always survives, and at least one snapshot always survives
- the count does not exceed `--max-delete` (default 8). Steady state is 0–2 per night, so a larger
  number means the clock, the policy or the listing is wrong. `--dry-run true` prints the full list
  even when the ceiling trips.

### Order of operations, and the interlock

Versioning runs **before** replication. The snapshot preserves the last known-good target state
before the mirror overwrites it, so a bad upstream day stays recoverable. It follows that **if
versioning fails, replication for that row is skipped** — overwriting a target whose previous state
could not be preserved is the one move that turns a bad day into data loss. Exit code 3 from
`couchdb-repv-version.sh` is the exception: it means the target database does not exist yet, so there
is no history to protect and `couchdb-repv.sh` replicates as normal.

### Things that are easy to get wrong

- **One-shot, not continuous.** `continuous:false`, so http 200 arrives only after the copy has
  finished and `docs_read`/`docs_written`/`doc_write_failures` are real. `--continuous true` is
  available; in that mode the script says plainly that 202 means *accepted*, checks
  `_scheduler/jobs`, and logs the `replication_id` needed to cancel the job.

- **`docs_read`/`docs_written` are CUMULATIVE LIFETIME TOTALS, not this run's work.** They come
  straight out of the `/_replicate` reply, and CouchDB reports the running totals of the
  replication's history. A one-shot run that finds its checkpoint and sees nothing new at the source
  **starts no new session and replays the previous session's history verbatim** — so an idle run and
  the run that actually copied the data print the *identical* number, to the document. The figure
  only ever climbs and never returns to 0. **Do not read an unchanged `docs_read` as "it re-copied
  everything", and do not read a rising one as "this run was busy".** CouchDB sets
  **`no_changes:true`** on a reply where it did nothing at all; that plus subtracting the previous
  history entry is how `couch_replicate` derives **`CDB_REP_DOCS_UPDATED`**, reported per run and as
  the `DOCS UPD` column of the per-database summary. Prefer that field; the raw totals are logged as
  `(cumulative, NOT this run)`.
  - Reading checkpoints by hand: a `_local` checkpoint doc sitting at **`rev 0-1` with a single
    history entry is a correctly resumed no-op**, not a checkpoint that is never reused. Judge
    checkpoint health by whether the replication id is *stable* across runs, never by its revision.
  - **Snapshot replications get a fresh replication id every run by construction**, because the
    target database name carries a timestamp. Each snapshot therefore leaves one `_local` doc behind
    in the base database, permanently. Harmless and excluded from `doc_count`, but it makes a base
    database's `_local_docs` listing look like checkpointing is broken.

- **Two timeouts.** `--timeout` (60s) bounds metadata calls; `--rep-timeout` (86400s) bounds the
  `_replicate` POST, which does not respond until a possibly multi-GB copy has finished. Cutting that
  short would abort curl while CouchDB carried on server-side, and report a failure for a copy that
  succeeded.

- **Preflight.** Every server and source database is checked before anything is written, so a bad
  password surfaces before the run is half done. A failing row is dropped and named in the summary;
  the run aborts only if every row fails, or under `--strict true`.

- **A run lock** (`flock`) — a nightly run that overruns its slot must not meet the next one head on.

- **Explicit `log()`, not `exec 1> >(logger -s ...)`.** The process-substitution form can lose the
  tail of the output — including the `FIN:` summary — when the script exits before logger flushes.
  Output goes to stderr and to syslog; `CDB_LOG_TAG` puts a whole run under one tag.

- `set -uo pipefail`, not `-e`, which would fight the accumulate-failures-and-continue behaviour.

### Exit codes

`0` ok · `1` something failed (the `FIN:` lines say what) · `2` usage or config error ·
`3` (`couchdb-repv-version.sh` only) nothing to snapshot, the target database does not exist yet.

---

## Tests

```
tests/run-all.sh --unit   lint + unit tests. No network, no config, no setup.
tests/run-all.sh          the above, then the live integration suite
tests/integration.sh teardown   delete every zz_test_* database
```

`tests/test-retention.sh`, `tests/test-env.sh` and `tests/test-inventory.sh` need nothing but bash and
GNU date. `retention_select` is written as a pure function precisely so the only code that deletes
data can be tested with no CouchDB in the way; `servers_load` / `resolve_server` / `parse_keep` are
written the same way for the same reason, since an alias decides *which machine* gets written to.

`tests/test-docs.sh` checks that `README.html` was rendered from the `README.md` beside it, that every
internal link resolves, and that the page fetches nothing at view time.

`tests/integration.sh` runs against the two servers the user names in `.repv-test-servers.csv` (see
[rule 1](#1-tests-need-credentials-the-user-supplies)) and refuses to touch any other host. Every
database it creates is prefixed `zz_test_`. It covers the ordering interlock, retention against 200
backdated snapshots, the `--max-delete` ceiling, the run lock, and failure injection for bad
credentials, a missing source database and an unreachable `rep-svr`.

It deliberately reads its config through the tool's own `servers_load` and `env_load`, so a bug in
either fails the suite rather than being papered over by a fixture — and so that setting the suite up
is the same exercise as setting up a real job.

---

## Documentation: README.md and README.html

`README.html` is a **generated file**. `README.md` is the source; the HTML is a self-contained
rendering of it for reading in a browser, with the CSS inlined so it works from a `file://` path on a
machine with no network — which is when you are most likely to be reading it.

**The rule: any commit that touches `README.md` must re-render `README.html` in the same commit.**

```
tools/render-readme.sh            regenerate README.html from README.md
tools/render-readme.sh --check    is README.html current? (no pandoc needed)
```

- **Never hand-edit `README.html`.** The next render silently discards the edit.
- `tests/test-docs.sh` **fails when the two have drifted**, and it runs as part of
  `tests/run-all.sh --unit`. That is what makes the rule enforceable rather than aspirational: the
  failure it catches is a README edit committed without a re-render, where nothing breaks and the
  HTML just goes on confidently describing how the scripts used to work.
- The check compares a `source-sha256:` stamp in the HTML against `README.md` as it stands. It needs
  only `sha256sum` — deliberately, so it still runs on a host that cannot render.
- **Rendering needs `pandoc`** (`apt install pandoc`). It is the one renderer, not one of several: a
  fallback producing different HTML would make `README.html` churn depending on who last rendered it,
  and the diff would stop being reviewable. `--check` does not need it.
- The renderer supplies its own template and stylesheet, and **refuses to write a file that
  references anything off-machine**.

---

## Branching

**Branch for every change; `main` takes no direct commits.** No exception for typos, comments or
one-line value changes. These scripts replicate live data and delete databases, so when a backup
turns out to be missing, truncated or stale, the question is always *which change did that, and
when did it land*. Every change arriving as its own merge commit is what makes that answer readable
off `git log --merges`.

- **Name branches `type/kebab-slug`**, using the same types as the commit prefixes: `feat/`, `fix/`,
  `docs/`, `chore/`, `test/`. For example `fix/replicate-status-check`.
- **Merge with `--no-ff`**, so each unit of work keeps its own merge commit even when it is a single
  commit. A fast-forward is exactly the case where the trace disappears.
- **Say what the change does to replication**, not just which file was edited.
- **Delete the branch once merged** — the merge commit is the record.
- Tag from `main` only.

---

## Conventions

- Credentials come from the env file and nowhere else. Never print, echo, or copy one into a log, a
  commit message, a test fixture, or a new file. `redact()` exists so that this holds even by
  accident; don't route around it.
- **`README.html` is generated** — edit `README.md` and run `tools/render-readme.sh`.
- `--dblist-dir DIR` is opt-in and writes `<date>-<host>-dbs.json`, a record of each source server's
  `_all_dbs`. The directory must already exist; the run warns and carries on if it does not.
- Comments explain *why*, in the terms of the problem — retention, replication, credentials — and
  never by reference to some other codebase.
