# CouchDB replication and versioned backups

Nightly scripts that mirror CouchDB databases from one server to another and keep
timestamped snapshots on the target, pruned on a **restic-style** retention policy
(keep 7 daily, 5 weekly, 12 monthly, 7 yearly — or whatever you choose).

What to replicate lives in a **CSV inventory** that names servers by short
aliases. What those aliases mean lives in a **servers table**, which holds no
passwords and is meant to be committed. Passwords live in a separate **`.env`
file**. None of it is baked into the scripts, so adding a database to the backup
set is a one-line config edit, not a code change on every host:

```csv
src-svr,targ-svr,rep-svr,db-name,keep
cloud,bak1,bak1,orders,7/5/12/7
```

> **Read this before your first live run:** versioning *deletes* databases.
> Jump to [Snapshots and retention](#snapshots-and-retention) and
> [Caveats](#caveats-read-these).

---

## Contents

- [Quick start](#quick-start)
- [The three files you write](#the-three-files-you-write)
  - [The env file](#1-the-env-file)
  - [The servers table](#2-the-servers-table)
  - [The inventory CSV](#3-the-inventory-csv)
  - [Picking `rep-svr`](#picking-rep-svr)
- [Running it](#running-it)
- [What a run looks like](#what-a-run-looks-like)
- [Snapshots and retention](#snapshots-and-retention)
- [Restoring from a snapshot](#restoring-from-a-snapshot)
- [The component scripts](#the-component-scripts)
- [Cron](#cron)
- [Caveats, read these](#caveats-read-these)
- [Troubleshooting](#troubleshooting)
- [Exit codes](#exit-codes)
- [Tests](#tests)
- [This README](#this-readme)
- [Command reference](#command-reference)

---

## Quick start

```bash
# 1. credentials, one entry per server. MUST be chmod 600.
cp repv-env.example /root/couchdb-repv/.repv-env
chmod 600 /root/couchdb-repv/.repv-env
$EDITOR /root/couchdb-repv/.repv-env

# 2. what your server aliases mean. No passwords in here.
cp repv-servers.csv.example /root/couchdb-repv/repv-servers.csv
$EDITOR /root/couchdb-repv/repv-servers.csv

# 3. what to back up
cp repv-inventory.csv.example /root/couchdb-repv/repv-inventory.csv
$EDITOR /root/couchdb-repv/repv-inventory.csv

# 4. does the config even make sense? No network, no changes, instant.
./couchdb-repv.sh \
    --inventory /root/couchdb-repv/repv-inventory.csv \
    --servers   /root/couchdb-repv/repv-servers.csv \
    --env       /root/couchdb-repv/.repv-env \
    --check

# 5. see exactly what it WOULD do - changes nothing
./couchdb-repv.sh \
    --inventory /root/couchdb-repv/repv-inventory.csv \
    --servers   /root/couchdb-repv/repv-servers.csv \
    --env       /root/couchdb-repv/.repv-env \
    --dry-run

# 6. when the plan looks right, drop --dry-run
./couchdb-repv.sh \
    --inventory /root/couchdb-repv/repv-inventory.csv \
    --servers   /root/couchdb-repv/repv-servers.csv \
    --env       /root/couchdb-repv/.repv-env
```

All three files are named explicitly and none is inferred. Name them whatever
suits the job — the tool is not tied to any particular fleet.

**Always `--check` an edited inventory, and dry-run a new one.** `--check`
answers "does this config mean what I think it means" in a second with no
network; `--dry-run` answers "what would tonight actually do" and prints the
same plan the real run will follow.

### Requirements

`bash` 4+, `curl`, GNU `date`, `logger`, and `flock` (optional but recommended).
No jq, no Python, nothing to install. Deploy by rsyncing **the whole directory** —
the scripts call each other:

```bash
rsync -av --exclude '.repv-*' --exclude '.git' ./ root@host:/opt/couchdb-repv/
```

---

## The three files you write

### 1. The env file

One `_USER` and one `_PASS` per CouchDB server, keyed by **hostname or IP** — the
hostname the alias resolves to, not the alias:

```ini
# /root/couchdb-repv/.repv-env   -   chmod 600

couchdb.example.com_USER=admin
couchdb.example.com_PASS=hunter2

203.0.113.10_USER=admin
203.0.113.10_PASS=s3cr3t-with-@-and-#-is-fine

192.168.66.9_USER=admin
192.168.66.9_PASS=another-password
```

- **`chmod 600` is enforced.** A group- or world-readable env file is refused
  outright. Override with `--allow-insecure-env` only if you have a reason.
- Values are taken **verbatim**. A password may contain `= # $ { } @ :` and
  spaces. Wrap in quotes if you like — one layer is stripped.
- **Do not put a trailing comment on a value line.** `PASS=abc  # note` makes the
  password `abc  # note`.
- Blank lines and `#` lines are ignored. `export ` prefixes and CRLF files are
  tolerated.

Renaming an alias never touches this file. Moving a server to a new address does.

If two CouchDBs share a box on different ports, a **port-qualified key wins** over
the bare hostname:

```ini
192.168.66.9_USER=admin          # everything on this box, unless overridden
192.168.66.9_PASS=another-password
192.168.66.9:6984_USER=other     # just the one on :6984
192.168.66.9:6984_PASS=different
```

Almost every fleet only ever needs the bare hostname form.

> **Why not just `source` it?** Because `couchdb.example.com_USER` contains dots and
> is not a legal shell variable name. The scripts parse this file themselves and
> never run `eval`, so a password containing `$(...)` stays literal text.

### 2. The servers table

What each alias means. **No credentials**, so unlike the env file this one is
meant to live in version control:

```csv
# /root/couchdb-repv/repv-servers.csv

alias,url
bak1,http://192.168.66.5:5984
bak2,http://192.168.66.11:5984
cloud,http://203.0.113.10:5984
```

Named by `--servers`, which is required like the other two. One table can serve
every job on a host, or each job can have its own.

- `alias` — letters, digits, `.` `_` `-`.
- `url` — `scheme://host[:port]`, no path, and **no credentials**: a url carrying
  them is refused, not warned about. The env file is the only source; a second
  one means two places to look when a password stops working.
- **Name aliases after the box, not the role.** The same machine is the
  `targ-svr` of one row and the `rep-svr` of another; `SRC_`/`TARG_`/`REP_`
  prefixes force it to appear twice under two names, and the two drift apart.
- Two aliases may point at one box. The first listed is the one used in logs.
- A **duplicate alias is an error**, not last-wins — an accidental duplicate
  would silently reroute every row naming it, and you would find out at restore
  time.
- Any bad entry refuses the **whole file**. A half-understood server table is not
  something to run a backup against: the rows that did parse still write to real
  machines.

Keeping this separate from the env file is the point. When a backup turns out to
be missing, *"which box was `bak1` in August?"* has to be answerable from `git
log` — and it cannot be if the topology lives in a `0600` file nobody reads.

### 3. The inventory CSV

One row per database per target. **The header row is authoritative** — column
order is free, but every column must be present:

```csv
src-svr,targ-svr,rep-svr,db-name,keep
cloud,bak1,bak1,app_meta,7/5/12/7
```

| column | meaning |
|---|---|
| `src-svr` | where the data comes from |
| `targ-svr` | where the mirror and its snapshots live |
| `rep-svr` | the node that **performs** the copy — see below |
| `db-name` | database name, same at both ends |
| `keep` | retention: `daily/weekly/monthly/yearly`, or `none` — see below |

The three server columns take an **alias** from the servers table. Credentials
never appear here at all; they are looked up from the env file by the hostname
the alias resolves to. An unknown alias stops that row and the error lists the
aliases that do exist.

A server column takes an alias and nothing else. A URL written there is read as
an alias nobody defined, and the error says so — there is no second accepted
form, because a parser with two of them has to explain both.


### Mirror without snapshots

Write **`none`** in the `keep` column for a database you want mirrored but never
snapshotted:

```csv
src-svr,targ-svr,rep-svr,db-name,keep
bak2,bak1,bak1,scratch_db,none
```

Versioning is not run for that row at all, so nothing is created and — this is
the important part — **nothing existing is deleted**. Switching a database to
mirror-only leaves the snapshots it already has exactly where they are; they
simply stop being maintained. Delete them by hand if you want the space.

The trade-off is that the target is overwritten each night with **no prior state
preserved**, so a bad day upstream is not recoverable from that target. Every
such row logs a `MIRROR-ONLY` line and the run summary counts them, so it stays
visible rather than becoming a silent gap in your backups.

**`0/0/0/0` is not the same thing** and stays refused — zero keeps would select
every existing snapshot for deletion. Use `none`.

`none` is case-insensitive.

`none` is the whole policy or none of it. `none/5/12/7` is not four integers, so
there is no half-sentinel to reject and no error to explain: the state simply
cannot be written down.

Blank lines and `#` lines are skipped. **There is no quoting and no escaping**:
fields are split on commas, which is exact because neither a CouchDB database
name nor an alias nor these URLs can contain one. A row whose field count doesn't match the
header is rejected and named, never silently misread.

To back one database up to two targets, write two rows.

### Picking `rep-svr`

CouchDB replication is a `POST` to one node's `/_replicate`. **That node does the
work, so it must reach both the source and the target.**

- **Usually: the target.** It pulls from the source. Set `rep-svr` = `targ-svr`.
- **LAN → cloud: the LAN node.** A CloudVendor box cannot reach `192.168.x`, so
  it cannot pull. The LAN node must drive the copy:

  ```csv
  # src is on the LAN, target is in the cloud, so the LAN node drives it
  src-svr,targ-svr,rep-svr,db-name,keep
  bak2,cloud,bak1,ledger_test,7/5/12/7
  ```

  Read that row as *"from `bak2` to `cloud`, driven by `bak1`"*. Aliases are what
  make this checkable at a glance — spelled out as three credentialled URLs, a
  wrong `rep-svr` is invisible on the line.

Getting this wrong shows up as `500 {"error":"db_not_found"}` even though the
database plainly exists — the replicating node just can't see it.

---

## Running it

```bash
couchdb-repv.sh --inventory FILE --servers FILE --env FILE [options]
```

One invocation per job. Nothing is inferred from anything else, so running a
second job is a second command line with its own three files.

| option | default | what it does |
|---|---|---|
| `--inventory FILE` | *required* | the CSV of what to replicate |
| `--env FILE` | *required* | the credentials file |
| `--servers FILE` | *required* | the alias table |
| `--log-tag TAG` | this script's name | syslog tag; give each cron job its own |
| `--check` | off | resolve the config, print what it means, stop. No lock, no network, no writes |
| `--dry-run true` | `false` | plan everything, change nothing. Bare `--dry-run` works too |
| `--sleep SECONDS` | `1` | pause between rows |
| `--max-delete N` | `8` | per-database ceiling on snapshot deletions in one run |
| `--continuous true` | `false` | live replication instead of one-shot — see [Caveats](#caveats-read-these) |
| `--strict true` | `false` | abort the whole run if *any* row fails preflight |
| `--skip-preflight` | off | skip the pre-run server checks |
| `--timeout SECONDS` | `60` | timeout for metadata requests |
| `--rep-timeout SECONDS` | `86400` | timeout for the copy itself |
| `--dblist-dir DIR` | off | also record each source server's `_all_dbs` into `DIR` |
| `--lock-file PATH` | one per inventory | run lock; pass `""` to disable |
| `--allow-insecure-env` | off | permit a group/world-readable env file |

Common invocations:

```bash
# the three files, once, so the rest of these can be short
CFG="--inventory /root/couchdb-repv/repv-inventory.csv \
     --servers   /root/couchdb-repv/repv-servers.csv \
     --env       /root/couchdb-repv/.repv-env"

# does this config mean what I think it means? instant, offline, safe any time
./couchdb-repv.sh $CFG --check

# rehearse an edited inventory
./couchdb-repv.sh $CFG --dry-run

# refuse to run at all if anything is misconfigured
./couchdb-repv.sh $CFG --strict true

# a large database that needs more than an hour to copy is already fine
# (--rep-timeout defaults to 24h); raise it only if you have something bigger
./couchdb-repv.sh $CFG --rep-timeout 172800
```

### Checking the config with `--check`

The alias table puts one hop between what the inventory says and which machine
gets written to. `--check` is where that hop is made visible — it resolves the
inventory, the servers table and the credentials, prints the result, and touches
nothing at all:

```
CHECK: inventory /root/couchdb-repv/repv-inventory.csv
CHECK: servers   /root/couchdb-repv/repv-servers.csv
CHECK:   DATABASE                      SRC     TARG    REP     KEEP
CHECK:   ledger_test         bak2    cloud   bak1    7/5/12/7
CHECK:   aa_orders_candidate  bak2    bak1    bak1    7/5/12/7
CHECK:   orders_test          bak2    bak1    bak1    none
CHECK: servers as resolved
CHECK:   bak1    ->  http://***:***@192.168.66.5:5984
CHECK:   bak2    ->  http://***:***@192.168.66.11:5984
CHECK:   cloud   ->  http://***:***@203.0.113.10:5984
CHECK: 3 usable row(s), 0 rejected
CHECK: inventory is usable - nothing was changed
```

The redacted URL is the useful half of that legend: `http://***:***@host` says
credentials were found and attached, `http://host` says none were.

It takes **no run lock**, so it is safe while last night's job is still going,
and it makes no network calls, so it says nothing about whether those servers are
actually up — that is what `--dry-run` and preflight are for. Exit `0` if every
row is usable, `1` if any row was rejected, `2` if the header is wrong. That
makes it usable as a pre-deploy gate.

### Order of operations

For every row, in this order:

1. **Snapshot** the target as it currently stands, then prune old snapshots.
2. **Replicate** the source over the target.

Versioning runs **first** on purpose: it preserves the last known-good target
state *before* the mirror overwrites it, so a bad day upstream stays recoverable.

It follows that **if versioning fails, that row is not replicated.** Overwriting
a target whose previous state could not be preserved is exactly what turns a bad
day into data loss. You'll see:

```
ERROR: ROW 4: SKIP replicate app_meta: versioning failed, refusing to overwrite
       192.168.66.5:5984/app_meta with its previous state unpreserved
```

The one exception is a target database that doesn't exist yet — there's no
history to protect, so it replicates normally and logs
`SKIP no target database ... yet`.

---

## What a run looks like

Output goes to **the screen and to syslog**, under the script's own name. Real
output from a healthy run:

```
INFO: holding run lock /tmp/couchdb-repv-repv-inventory.csv.lock
INFO: loaded 4 credential entries from /root/couchdb-repv/.repv-env
INFO: inventory header OK (8 columns)
INFO: inventory: 1 usable row(s), 0 rejected
INFO: preflight: checking servers and source databases
INFO: preflight OK  192.168.66.30:5984
INFO: preflight OK  192.168.66.31:5984
INFO: preflight: 0 of 1 row(s) unusable
INFO: ROW 2: app_meta 192.168.66.30:5984 -> 192.168.66.31:5984
INFO: versioning app_meta on 192.168.66.31:5984 (keep daily=7 weekly=5 monthly=12 yearly=7, max-delete=8, dry-run=false)
INFO: found 5 existing snapshot(s) of app_meta on 192.168.66.31:5984
INFO: CREATE app_meta_snap_20260825-132338 on 192.168.66.31:5984 from app_meta (3 docs)
INFO: OK snapshot app_meta_snap_20260825-132338 verified: doc_count=3, docs_read=3 docs_written=3
INFO: KEEP   app_meta_snap_20260825-132338 (daily,weekly,monthly,yearly)
INFO: KEEP   app_meta_snap_20260824-020500 (daily)
INFO: KEEP   app_meta_snap_20260823-020500 (daily,weekly)
INFO: KEEP   app_meta_snap_20260820-020500 (daily)
INFO: retention: 6 kept, 0 to delete (of 6 snapshots)
INFO: FIN: app_meta on 192.168.66.31:5984: snapshot 20260825-132338, 6 kept, 0 deleted
INFO: replicate app_meta: 192.168.66.30:5984 -> 192.168.66.31:5984 (driven by 192.168.66.31:5984, continuous=false, dry-run=false)
INFO: app_meta: 3 docs updated in 2s
INFO: app_meta: lifetime totals docs_read=3 docs_written=3 doc_write_failures=0 (cumulative, NOT this run)
INFO: FIN: app_meta: 192.168.66.30:5984 -> 192.168.66.31:5984 OK (target doc_count 3 -> 3)
INFO: FIN: per-database summary
INFO: FIN:   DATABASE  TARGET             VERSIONS   DOCS UPD    TIME
INFO: FIN:   app_meta  192.168.66.31:5984         6          3      2s
INFO: FIN: rows 1 processed of 1 usable (0 unparsable, 0 failed preflight)
INFO: FIN: versioning 1 OK, 0 skipped (no target db yet), 0 FAILED
INFO: FIN: replication 1 OK, 0 skipped
INFO: FIN: 0 failure(s)
```

Every `KEEP` line says **why** that snapshot survived, so a surprising survivor
can always be explained from the log.

### The per-database summary

Every run ends with one line per processed row, in inventory order:

```
FIN: per-database summary
FIN:   DATABASE             TARGET             VERSIONS   DOCS UPD    TIME
FIN:   orders      192.168.66.31:5984         1          2      6s   1 snapshot(s) pruned
FIN:   app_meta             192.168.66.31:5984         1          0      7s   already current
FIN:   orders_test 192.168.66.31:5984         -          0      4s   mirror-only, no snapshots
FIN:   orders_test 192.168.66.30:5984         0          9      5s   first copy, nothing to snapshot yet
```

| column | meaning |
|---|---|
| `DATABASE` | database name. **Not** unique — the same database replicated to two targets is two rows. |
| `TARGET` | which server this row wrote to. This is what tells those two rows apart. |
| `VERSIONS` | snapshots of this database now kept on that target. `-` means the row is mirror-only (`keep` is `none`), so no snapshot is ever taken. |
| `DOCS UPD` | documents **this run** actually wrote. `0` with `already current` means the target was up to date — not that the row was skipped. |
| `TIME` | wall-clock for the whole row, versioning plus replication. Excludes `--sleep`, which is pacing, not work. |

**`DOCS UPD` is not `docs_read`/`docs_written`.** Those are cumulative lifetime
totals for the replication and a run that copies nothing replays the previous
session's history verbatim, so they read identically on a busy run and an idle
one. `DOCS UPD` is derived: CouchDB's `no_changes` flag when it did nothing, and
otherwise this history entry's total minus the previous one's. It counts
**updates as well as insertions**, so it moves even when `doc_count` does not.

A run with pruning:

```
INFO: retention: 2 kept, 5 to delete (of 7 snapshots)
INFO: DELETE app_meta_snap_20260823-020500 on 192.168.66.31:5984: http=200
INFO: DELETE app_meta_snap_20260820-020500 on 192.168.66.31:5984: http=200
...
INFO: FIN: app_meta on 192.168.66.31:5984: snapshot 20260825-132356, 2 kept, 5 deleted, 0 delete(s) FAILED
```

### Reading the logs

```bash
# this job, today
journalctl -t repv --since today

# just the failures
journalctl -t repv --since today | grep ERROR

# the end-of-run summary
journalctl -t repv --since today | grep 'FIN:'

# on a host without journald
grep repv /var/log/syslog | grep ERROR
```

**Match on `ERROR`, not on HTTP status.** CouchDB reports most replication
problems as `500`, not `4xx` — a missing source database comes back as
`500 {"error":"db_not_found"}`.

**Passwords never appear.** Every log line is redacted: `http://admin:hunter2@h`
prints as `http://***:***@h`, on screen and in syslog.

---

## Snapshots and retention

Each run copies the target database to a timestamped snapshot **on the same
server**:

```
app_meta                          the live mirror
app_meta_snap_20260825-020501     today
app_meta_snap_20260824-020458     yesterday
app_meta_snap_20260731-020502     end of July
app_meta_snap_20251231-020455     end of 2025
```

Then it deletes the snapshots outside your keep policy — the same selection
`restic forget` makes.

### How the policy actually works

Walking newest to oldest, a snapshot is kept when it **opens a new bucket** of a
type that still has keeps left. Buckets are the day, the ISO week, the month and
the year. A snapshot survives if *any* of the four keeps it.

Two consequences that surprise people:

- **These are not "the last N days".** They're the last N snapshots that start a
  new day/week/month/year. A gap in the series does not burn a keep — if you
  didn't run for a fortnight, a daily keep of 7 still holds seven *snapshots*,
  just older ones.
- **Several runs in one day collapse to one snapshot.** Only the newest snapshot
  of a given day counts as that day's daily, so a mid-day re-run is safe: it
  replaces the morning's snapshot rather than consuming a second slot.

`7,5,12,7` settles at **about 31 snapshots per database**. Every snapshot is a
full copy, so budget disk accordingly.

### When it will not delete

Nothing is deleted unless **all** of these hold:

- A new snapshot was created **and verified** — HTTP 200, `"ok":true`,
  `doc_write_failures:0`, and its `doc_count` matches the live database. No good
  new snapshot means **no deletions at all**, ever.
- The name matches `<db>_snap_<YYYYMMDD-HHMMSS>` exactly. Nothing else is even a
  candidate.
- It isn't the live database, the snapshot just taken, or a `_users` /
  `_replicator` style system database.
- The newest snapshot always survives, and at least one snapshot always survives.
- The count doesn't exceed `--max-delete` (default **8**).

The `--max-delete` ceiling is a circuit breaker. Steady state is 0–2 deletions a
night, so a bigger number means the clock, the policy or the listing is wrong:

```
ERROR: refusing to delete 47 snapshots of app_meta in one run: --max-delete is 8
ERROR: review the list with --dry-run true, then raise --max-delete deliberately if it is correct
```

Do exactly that — `--dry-run true` prints the full list *even when the ceiling
trips* — and only then raise it:

```bash
./couchdb-repv-version.sh --rep-svr URL --targ-svr URL --db-name app_meta \
    --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-yearly 7 \
    --dry-run true                    # what would go?
```

### Timing: a snapshot is one cycle behind

Versioning runs before replication, so **`app_meta_snap_20260825-020501` holds
the target as it stood after the 24 August run**, not the 25th. That's the point
— it's the copy you reach for when the 25th brought something bad. The stamp is
when the snapshot was *taken*, not the age of the data in it.

---

## Restoring from a snapshot

There's no restore script; a restore is a judgement call, not a cron job. The
mechanics are one `curl`. **Always restore to a new name first and inspect it.**

```bash
TARG='http://admin:PASSWORD@192.168.66.5:5984'

# 1. what do I have?
curl -s "$TARG/_all_dbs" | tr ',' '\n' | grep app_meta

# 2. how big is the snapshot I want?
curl -s "$TARG/app_meta_snap_20260824-020458" | head -c 300

# 3. restore it alongside the live database, NOT over it
curl -X POST "$TARG/_replicate" -H 'Content-Type: application/json' -d '{
  "source": "'"$TARG"'/app_meta_snap_20260824-020458",
  "target": "'"$TARG"'/app_meta_restored",
  "create_target": true,
  "continuous": false
}'

# 4. check it, then swap it in yourself when you are satisfied
curl -s "$TARG/app_meta_restored" | head -c 300
```

If you're restoring because the source is bad, **comment that row out of the
inventory first**, or the next nightly run will replicate the bad data straight
back over your work.

---

## The component scripts

The nightly job is built from two standalone scripts you can also run by hand on
a single database. Useful for one-offs, for testing, and for recovery.

### `couchdb-repv-version.sh` — snapshot and prune one database

```bash
./couchdb-repv-version.sh \
    --rep-svr  http://admin:pw@192.168.66.5:5984 \
    --targ-svr http://admin:pw@192.168.66.5:5984 \
    --db-name  app_meta \
    --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-yearly 7 \
    --dry-run true
```

Snapshots are target-to-target — the backup host copies from itself — so there's
no `--src-svr`. Options: `--max-delete N` (default 8), `--timeout`,
`--rep-timeout`, `--dry-run`.

### `couchdb-repv-replicate.sh` — copy one database

```bash
./couchdb-repv-replicate.sh \
    --rep-svr  http://admin:pw@192.168.66.5:5984 \
    --src-svr  http://admin:pw@203.0.113.10:5984 \
    --targ-svr http://admin:pw@192.168.66.5:5984 \
    --db-name  app_meta
```

Options: `--continuous true|false` (default `false`), `--create-target
true|false` (default `true`), `--timeout`, `--rep-timeout`, `--dry-run`.

> Credentials typed on a command line land in your shell history and in `ps`
> output. For anything routine, use the inventory.

---

## Cron

```cron
5 2 * * * /opt/couchdb-repv/couchdb-repv.sh --log-tag repv --inventory /root/couchdb-repv/repv-inventory.csv --servers /root/couchdb-repv/repv-servers.csv --env /root/couchdb-repv/.repv-env
```

**Give each job its own `--log-tag`.** It is what separates two jobs in syslog,
and without it they both log under `couchdb-repv.sh` and interleave.

The scripts **exit 1 if anything failed**, so with `MAILTO=` set, cron mails you
on a bad night and stays quiet on a good one. Everything is in syslog either way.

Each inventory gets its own lock, so these two don't block each other even though
they fire in the same minute. A run that overruns into the next night's slot is
refused rather than doubled up:

```
ERROR: another run holds /tmp/couchdb-repv-...lock - exiting rather than running two at once
```

**Suggested rollout:** put the job in cron with `--dry-run true` for a week
first, read the mail it sends, and drop the flag only once the plan it prints
looks right every night.

---

## Caveats, read these

**Versioning deletes databases.** That's the whole point of a retention policy,
but it is a delete. The guards above make it hard to delete the wrong thing —
they can't make it impossible to delete the right thing under a policy you
didn't mean. Dry-run any policy change.

**The mirror is one-shot, not live.** Replication runs at 02:05 and finishes. The
target is as fresh as the last run, **not** live. If you look at a backup at 4pm
you're seeing this morning. `--continuous true` switches to live replication, but
then HTTP 202 only means *accepted* — the job can still fail asynchronously, and
you have to check `_scheduler/jobs` to know it's healthy.

**Snapshots are full copies on the same server.** No deduplication, no
compression, and no protection against that server dying. This is version
history, **not** offsite backup — you still want a cold copy of the target's
data directory somewhere else.

**`doc_count` is not a checksum.** The snapshot check catches a truncated or
failed copy. It does not prove document-level equality.

**Deleted documents don't reduce `doc_count` until the tombstone replicates**, so
an occasional
`WARN: target doc_count=41 differs from source doc_count=42` is normal, not a
failure. Persistent or growing drift is worth looking into.

**A row backing up to two targets is two rows**, and each keeps its own snapshots
on its own target.

**A mirror-only row has no snapshot protection.** `keep` of `none` mirrors
without versioning, which means the target is overwritten nightly with nothing
preserved beforehand. That is a reasonable thing to want; be deliberate about it.

**A database named like a snapshot will be treated as one.** Don't create a real
database called `something_snap_20260825-020501`.

**Don't run two jobs from one inventory** — the lock will refuse the second.
Split the inventory instead.

**Timestamps are local time.** Around a daylight-saving change a day may hold two
snapshots or none. Retention handles both correctly; the bucket just moves.

---

## Troubleshooting

**`env file ... is mode 644; it holds passwords and must not be group/other readable`**
→ `chmod 600` the env file.

**`server alias 'bak1' (192.168.66.5:5984) has no credentials: the env file needs 192.168.66.5_USER and 192.168.66.5_PASS`**
→ Add exactly those two keys. The env file is keyed by the **hostname the alias
resolves to**, never by the alias itself.

**`unknown server alias 'bak1' - the servers file defines: cloud bak2 bak1`**
→ A typo in the inventory, or an alias you never added to the servers table.

**`unknown server alias 'http://admin:pw@host:5984'`**
→ A URL where an alias belongs. Server columns hold aliases only: add the server
to the servers table and write its alias here.

**`--servers is required`**
→ All three files are named explicitly. There is no inferred path.

**`servers file ...: 1 bad entr(ies) - refusing to run`**
→ Unlike a bad inventory row, a bad servers entry stops everything. The rows that
*did* parse still write to real machines, so a half-understood table is not
something to proceed on. Fix the line it names.

**`header is missing column(s): keep`**
→ The header row is authoritative and this one has no `keep` column. Retention is
one column: `7/5/12/7`, or `none`.

**`keep: daily must be a non-negative integer, got 'none' in 'none/5/12/7'`**
→ In the single-column form, `none` means the whole policy. There is no partial
form — write `none`, or four numbers.

**`inventory line 4: has 4 fields, header has 5`**
→ A missing or extra comma on that line. The row is rejected rather than guessed
at, which is deliberate — a shifted field would put a retention count where a
database name should be.

**`keep: 0/0/0/0 would select every existing snapshot for deletion`**
→ Zero keeps would select every snapshot for deletion, so it is refused. If you
meant "mirror but never snapshot", write `none`.

**`servers file ... line 2: 'bak1' has credentials in its url`**
→ Credentials belong in the `--env` file, keyed by hostname. The servers table is
meant to be committed.

**`header is missing column(s): rep-svr`**
→ Add it — see [Picking `rep-svr`](#picking-rep-svr).

**`http=401: {"error":"unauthorized","reason":"Name or password is incorrect."}`**
→ Wrong credentials for that host. Preflight catches this before anything is
written. `--check` will not: it makes no network calls, and a resolved
`http://***:***@host` only means credentials were *found*, not that they work.

**`500 {"error":"db_not_found"}` but the database exists**
→ Almost always `rep-svr` pointing at a node that can't reach the source. Check
from that node: `curl -s http://user:pw@SOURCE:5984/dbname`.

**`SKIP replicate ...: versioning failed`**
→ Working as designed. Fix the versioning error above it — the target is
untouched, and nothing was deleted.

**`refusing to delete 47 snapshots ... --max-delete is 8`**
→ Review with `--dry-run true`, then raise `--max-delete` if the list is right.

**`another run holds /tmp/couchdb-repv-....lock`**
→ Last night's run is still going, or died leaving the lock held. Check with
`ps aux | grep couchdb-rep`.

**Timed out after 86400s**
→ The copy is probably **still running server-side**. Check
`curl -s http://user:pw@REPSVR:5984/_scheduler/jobs` before retrying — a blind
retry stacks up duplicate jobs.

---

## Exit codes

| code | meaning |
|---|---|
| `0` | everything succeeded |
| `1` | something failed — the `FIN:` lines list what |
| `2` | usage or config error — bad flag, missing column, unreadable file |
| `3` | *(`couchdb-repv-version.sh` only)* nothing to snapshot; the target database doesn't exist yet |

---

## Tests

```bash
tests/run-all.sh --unit     # lint + unit only. No network, no config, no setup.
tests/run-all.sh            # the above, then the live integration suite
tests/integration.sh keep   # run, then leave the test databases in place
tests/integration.sh teardown
```

**The integration suite needs two CouchDB servers that you provide.** There is no
default and no bundled fixture: it will not start until you have written both
files, so it cannot run against whatever happens to be on the network.

```bash
cp repv-test-servers.csv.example .repv-test-servers.csv   # test0 and test1
$EDITOR .repv-test-servers.csv

cp repv-test-env.example .repv-test-env
chmod 600 .repv-test-env                                   # refused otherwise
$EDITOR .repv-test-env
```

Or point `CDB_TEST_SERVERS` / `CDB_TEST_ENV` elsewhere. Both files are
gitignored, and both use the tool's own formats, read by the tool's own parsers.

> **These two servers must be disposable.** The suite creates and deletes
> databases on them. It only ever touches names prefixed `zz_test_`, and only on
> the two hosts that table names — but the code doing the deleting is the code
> under test. Use scratch containers or throwaway VMs, with credentials that are
> not reused anywhere, and never point it at anything holding data you'd miss.

`repv-test-inventory.csv.example` is there for a manual smoke run — `--check`,
then `--dry-run`, then a real run — before you trust the same three files against
a fleet that matters. The suite does not read it; it generates its own.

The unit tests need only bash and GNU date, and cover the two things that decide
what happens to real data with nothing in the way:

- **`test-retention.sh`** — `retention_select`, the one piece of code that
  deletes. Written as a pure function precisely so it can be tested with no
  CouchDB in the way.
- **`test-inventory.sh`** — the servers table, alias resolution, credential
  derivation and the `keep` grammar. An alias is what decides *which machine*
  gets written to, so it gets the same treatment.
- **`test-env.sh`** — env parsing, token expansion, URL handling, redaction.
- **`test-docs.sh`** — that `README.html` was rendered from this `README.md`. See
  [This README](#this-readme).

The integration suite replicates `test0` → `test1` and **refuses to touch any
host that is not one of those two**. Every database it creates is prefixed
`zz_test_`, which is also the only prefix `teardown` removes. It covers the
ordering interlock, retention over 200 backdated snapshots, the delete ceiling,
the run lock, and failure injection for bad credentials, a missing source
database and an unreachable `rep-svr`.

---

## This README

`README.html` is a **generated file** — a self-contained rendering of this
`README.md` for reading in a browser. The CSS is inlined and nothing is fetched
at view time, so it opens from a `file://` path on a machine with no network,
which is the situation you are usually in when you need it.

```bash
tools/render-readme.sh            # regenerate README.html from README.md
tools/render-readme.sh --check    # is README.html current?
```

**Any change to `README.md` must be re-rendered in the same commit.** Don't edit
`README.html` by hand — the next render discards the edit without saying so.

`tests/test-docs.sh` fails when the two have drifted, so `tests/run-all.sh
--unit` catches a README edit committed without a re-render. That failure is
worth having: nothing breaks when the HTML goes stale, it just carries on
confidently describing how the scripts used to work.

Rendering needs `pandoc` (`apt install pandoc`). `--check` doesn't — it compares
a `source-sha256:` stamp in the HTML against the Markdown, so the check still
runs on a host that can't render, rather than being skipped there and quietly
ceasing to be a check.

---

## Command reference

```
couchdb-repv.sh              the entry point: run this
couchdb-repv-version.sh      snapshot + prune ONE database
couchdb-repv-replicate.sh    copy ONE database
couchdb-repv-common.sh       shared library (sourced, not run)
```

Config files, none of which are code:

```
repv-servers.csv             alias -> url. No passwords. Safe to commit.
repv-inventory.csv           what to replicate and how long to keep it
.repv-env                    passwords, 0600, never committed
```

Those are the names the shipped `.example` files copy to; call them whatever
suits the job, since all three are passed explicitly.

Every one of them takes `--help` (except `couchdb-repv-common.sh`, which is a
library — it is sourced, never run).

```bash
./couchdb-repv.sh --help
./couchdb-repv-version.sh --help
```
