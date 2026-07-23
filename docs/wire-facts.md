# NodeDB 0.4.0 wire facts (spiked 2026-07-23)

Ground-truth facts recorded from a live NodeDB 0.4.0 container for tasks 10-15
(pgwire decoding, OID mapping, array/vector parsing, error decoding). Every
value below is a verbatim capture — copy it, don't re-derive it — unless
explicitly marked as a note/observation.

## Toolchain installed

- `crystal --version` → `Crystal 1.21.0 [57cf7da50] (2026-07-16)` / `LLVM: 20.1.8` / `Default target: x86_64-unknown-linux-gnu`
- `shards --version` → `Shards 0.20.0 [b2b98ca] (2025-12-19)`
- `psql --version` → `psql (PostgreSQL) 16.14 (Ubuntu 16.14-0ubuntu0.24.04.1)`
- Installed via `curl -fsSL https://crystal-lang.org/install.sh | sudo bash`; psql was already present (`apt` install not needed).

## Docker image

- **Reference pinned:** `farhansyah/nodedb:0.4.0`
- **Digest:** `farhansyah/nodedb@sha256:e29309aeb3c8e83070a9e0ee276fb6df178263aa782819cd928c830b4cac3ae4`
- An exact semantic `0.4.0` tag exists on Docker Hub (confirmed via
  `curl -s "https://hub.docker.com/v2/repositories/farhansyah/nodedb/tags?page_size=100" | jq -r '.results[].name' | sort -V`,
  which listed `... 0.3.0 0.3.0-amd64 0.3.0-arm64 0.4.0 0.4.0-amd64 0.4.0-arm64 latest`),
  so no digest-fallback-from-`latest` was needed.
- Exposed ports per image config: `4317/tcp, 4318/tcp, 6432/tcp, 6433/tcp, 6480/tcp, 9090/tcp`.
- Image env: `PATH=...`, `SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt`, `NODEDB_HOST=0.0.0.0`, `NODEDB_DATA_DIR=/var/lib/nodedb`. No default user/password/db baked into env — credentials are generated at first boot (see below).

## Container run

```bash
docker run -d --name nodedb-test -p 16432:6432 -p 16433:6433 farhansyah/nodedb:0.4.0
```

- Host port **16432** → container pgwire port 6432 (per task constraint — the live 0.3.0 instance on this box owns 6432/6433 on its tailscale IP, untouched).
- Host port 16433 → container native port 6433 (mapped for convenience/future tasks; not required by the brief).
- Container is left **running** (`docker ps` shows `Up`, container name `nodedb-test`) for downstream tasks.
- **Surprise:** Docker reports container health as `unhealthy` (`docker inspect` → `Health.Log` shows repeated `healthcheck failed: status 404`). This is the image's built-in `HEALTHCHECK` hitting an endpoint that 404s — it does **not** affect the database itself; every SQL/wire operation below worked normally. Later tasks should ignore `docker ps` health status and verify liveness via an actual query instead.
- No restart policy is set on the container (`docker inspect .HostConfig.RestartPolicy` → `null`/none). If the container is ever recreated, a **new random superuser password is generated** (see Auth below) — later tasks must re-read it from `docker logs nodedb-test` if that happens, rather than assuming the password recorded here still applies.

### First-boot log excerpt (verbatim, relevant lines)

```
[WARN] nodedb::bootstrap::wal_init: redb catalog stored unencrypted; use a dm-crypt/LUKS volume for at-rest catalog encryption catalog=/var/lib/nodedb/system.redb
[WARN] nodedb_cluster::transport::credentials: cluster transport running WITHOUT authentication — any peer reaching the QUIC port can forge Raft RPCs. Only use on isolated networks. Set cluster.insecure_transport = false and provide TLS credentials for production. node_id=1

  ╔══════════════════════════════════════════════════════════════╗
  ║         AUTO-GENERATED SUPERUSER PASSWORD (FIRST RUN)        ║
  ╠══════════════════════════════════════════════════════════════╣
  ║  user:     nodedb                                            ║
  ║  password: CpUb8WB8XRncTHmuKZPTfovE                          ║
  ║  saved to: /var/lib/nodedb/.superuser_password               ║
  ║                                                              ║
  ║  Override via NODEDB_SUPERUSER_PASSWORD or auth config.      ║
  ╚══════════════════════════════════════════════════════════════╝

  NodeDB v0.4.0
  ─────────────────────────────────────
  git_commit          : 26ac75c
  build_date          : 2026-07-22
  build_profile       : release
  rust_version        : rustc 1.97.1 (8bab26f4f 2026-07-14)
  wire_format_version : 1
  ─────────────────────────────────────
  hostname            : e0a0ca1a4bbc
  pid                 : 1
  pgwire_port         : 6432
  http_port           : 6480
  native_port         : 6433
  cluster_mode        : single-node
  data_dir            : /var/lib/nodedb
  auth_mode           : Password
```

(4 subsequent `ERROR` lines about `leader-change no-op committed at index where a proposer was waiting; surfacing RetryableLeaderChange` from `nodedb::control::distributed_applier::applier` at single-node Raft bootstrap — benign startup noise, not connection-affecting.)

## Auth / connect (the winning connection)

- **Connect:** `host=localhost port=16432 user=nodedb dbname=nodedb`
- **Auth mode:** `scram-sha-256` (confirmed at the wire level, not just from the log's "Password" label — see below). psql connects transparently via `PGPASSWORD` env var; no `sslmode` needed (plain TCP, no TLS offered — psql's default `sslmode=prefer` silently falls back).
- **Password:** `CpUb8WB8XRncTHmuKZPTfovE` (auto-generated on first boot of *this* container instance; see the "no restart policy" caveat above — this exact string is only valid for this running container).
- First psql attempt in the brief's order (`user=nodedb dbname=nodedb`) connected successfully — no need to fall back to `user=postgres dbname=postgres` (that one also happens to work, since `nodedb` is superuser and `postgres`-named db/role are accepted too, but `user=nodedb dbname=nodedb` is the recorded winner).
- **Wire-level auth confirmation:** a raw pgwire probe (Python, see Method below) sent the StartupMessage and read the first `AuthenticationRequest` message before any password was sent:
  ```
  raw bytes: b'R\x00\x00\x00\x17\x00\x00\x00\nSCRAM-SHA-256\x00\x00'
  type: R  length: 23  auth_code: 10 (AuthenticationSASL)  mechanism list: "SCRAM-SHA-256"
  ```
  So `auth_mode: Password` in the startup banner means SCRAM-SHA-256 SASL, not cleartext/MD5. A full SCRAM-SHA-256 handshake (client-first → server-first with salt+iterations → client-final with proof → server SASLFinal → AuthenticationOk) was implemented and completed successfully in the probe script — confirms NodeDB 0.4.0 implements real RFC 5802 SCRAM-SHA-256, not just the auth_code label.

## `SHOW server_version`

```
   server_version    
---------------------
 15.0 (NodeDB 0.4.0)
(1 row)
```

Verbatim string: `15.0 (NodeDB 0.4.0)` — confirms 0.4.x. (Not blocked; proceeded.) Note the Postgres-compat version number `15.0` is a compatibility marker, not NodeDB's own version — NodeDB's own version `0.4.0` is embedded in parens and also shown in the startup banner (`NodeDB v0.4.0`, `git_commit: 26ac75c`, `build_date: 2026-07-22`).

## Method used for per-column OIDs (in place of a working `\gdesc`)

`\gdesc` piped through `psql -c` fails immediately because the whole string
(including the literal backslash) gets sent to the server as one statement:

```
$ psql "host=localhost port=16432 user=nodedb dbname=nodedb" -c "SELECT id, n, f, b, ts, emb FROM spike_t \gdesc"
ERROR:  parse error: sql parser error: Expected: end of statement, found: \ at Line: 1, Column: 42
```

Running it properly via stdin (so psql's own lexer recognizes the
backslash-command) gets further — psql performs its normal Describe
round-trip against the server and then tries to render the result as a
client-side synthetic `VALUES` query, which NodeDB's SQL engine does not
support as a standalone query body:

```
$ psql "host=localhost port=16432 user=nodedb dbname=nodedb" <<'EOF'
SELECT id, n, f, b, ts, emb FROM spike_t \gdesc
EOF
ERROR:  unsupported: query body type: VALUES ('id', '25'::pg_catalog.oid, 0), ('n', '20'::pg_catalog.oid, 0), ('f', '701'::pg_catalog.oid, 0), ('b', '16'::pg_catalog.oid, 0), ('ts', '1114'::pg_catalog.oid, 0), ('emb', '25'::pg_catalog.oid, 0)
```

This error message is actually a perfect cross-check: it's psql's own
client-computed OID list (from the real Describe response it got back
from the server before trying to render it), so it independently confirms
every OID below.

**Primary method used:** a small Python script (`wire_probe.py`, written for
this spike) that speaks the pgwire protocol directly over a raw TCP socket —
implements StartupMessage, full SCRAM-SHA-256 SASL auth, simple-Query
protocol (`Q` message), and parses `RowDescription` (`T`), `DataRow` (`D`),
`CommandComplete` (`C`), and `ErrorResponse` (`E`) messages, printing exact
field OIDs and raw (undecoded) field bytes. This is the authoritative source
for every OID and raw byte string recorded in this document — psql's
formatted (`-A -F'|' -t`) output was cross-checked against it and matched.

## OIDs observed (query: `SELECT id, n, f, b, ts, emb FROM spike_t`)

Collection DDL used: `CREATE COLLECTION spike_t (id TEXT PRIMARY KEY, n INT, f FLOAT, b BOOLEAN, ts TIMESTAMP, emb FLOAT[])`

| column | NodeDB DDL type | OID observed | Postgres OID meaning | format_code |
|---|---|---|---|---|
| `id`  | `TEXT`      | **25**   | text | 0 (text) |
| `n`   | `INT`       | **20**   | int8 (bigint) | 0 (text) |
| `f`   | `FLOAT`     | **701**  | float8 (double precision) | 0 (text) |
| `b`   | `BOOLEAN`   | **16**   | bool | 0 (text) |
| `ts`  | `TIMESTAMP` | **1114** | timestamp without time zone | 0 (text) |
| `emb` | `FLOAT[]`   | **25**   | **text**, not an array type | 0 (text) |

Brief's expected template line for comparison: `id=25 n=23 f=701 b=16 ts=1114 emb=<1021|1022>`.

**Two deviations from the brief's expectation — record and propagate to later tasks:**

1. **`n INT` reports OID 20 (int8/bigint), not 23 (int4/integer).** NodeDB's `INT` DDL keyword maps to a wire-level 8-byte integer, not Postgres's 4-byte `int4`. Task 10/11 (decoders) must treat NodeDB `INT` columns as `int8`-shaped on the wire, not `int4`.
2. **`emb FLOAT[]` reports OID 25 (text), not 1021 (`float4[]`) or 1022 (`float8[]`).** NodeDB does not send FLOAT[] as a native Postgres array-of-float8 wire type — the column's reported type is plain `text`, and the payload is a JSON array of stringified floats (see Vector text below). **Task 12's array/vector parser must decode this column as: read as text, then JSON-parse into a string array, then parse each string as float** — not as a pg-standard array literal (`{...}`) and not as a binary float array.

Raw wire capture backing this table (`RowDescription` from the probe script):

```
RowDescription:
  name='id' type_oid=25 type_len=0 type_mod=0 format_code=0
  name='n' type_oid=20 type_len=0 type_mod=0 format_code=0
  name='f' type_oid=701 type_len=0 type_mod=0 format_code=0
  name='b' type_oid=16 type_len=0 type_mod=0 format_code=0
  name='ts' type_oid=1114 type_len=0 type_mod=0 format_code=0
  name='emb' type_oid=25 type_len=0 type_mod=0 format_code=0
```

(`type_len` and `type_mod` were both reported as `0` for every column — NodeDB does not populate Postgres's usual typlen/typmod values on the wire; do not rely on them.)

## Timestamp text (verbatim)

Inserted: `'2026-07-23 10:00:00'` (via `INSERT INTO spike_t (...) VALUES ('a', 42, 1.5, true, '2026-07-23 10:00:00', ARRAY[0.1, 0.2, 0.3])`)

Round-tripped raw wire bytes for the `ts` column on `SELECT`:

```
raw_bytes=b'2026-07-23 10:00:00'
```

**Exact text:** `2026-07-23 10:00:00` — `YYYY-MM-DD HH:MM:SS`, no fractional seconds, no timezone offset, no `T` separator. Echoed byte-for-byte identical to what was inserted (no server-side reformatting observed for whole-second timestamps).

## Vector text (verbatim)

Inserted: `ARRAY[0.1, 0.2, 0.3]` into `emb FLOAT[]`.

Raw wire bytes for the `emb` column on `SELECT` (format_code 0 / text):

```
raw_bytes=b'["0.1","0.2","0.3"]'
```

**Exact text:** `["0.1","0.2","0.3"]` — a **JSON array of JSON strings** (each float rendered as a quoted decimal string), **not** the Postgres-standard array literal `{0.1,0.2,0.3}`. psql's own pretty-printed and unaligned (`-A -F'|' -t`) output rendered the identical text: `["0.1","0.2","0.3"]`.

**This differs from the brief's expected pg-standard `{0.1,0.2,0.3}` format — Task 12's array/vector parser must parse this column as JSON, not as a pg array literal.**

## `SEARCH` statement (vector KNN)

Command run (per brief): `SEARCH spike_t USING VECTOR(emb, ARRAY[0.1, 0.2, 0.3], 1)`

- **psql pretty output:** empty column header (`--`), `(0 rows)`.
- **Raw wire capture:** `RowDescription` with **zero columns**, followed by `CommandComplete: b'SELECT 0\x00'` (note: `SELECT`, not a `SEARCH`-specific command tag).
- Retested after inserting a second row (`'b'`, `emb=ARRAY[0.9,0.8,0.7]`) and with `k=1` and `k=2` — same result every time: 0 columns, 0 rows, `SELECT 0`.
- **No ErrorResponse was produced** — the statement parses and executes successfully, it just never returns rows/columns in this container/setup as spiked. Root cause not investigated further (out of scope for this task — no vector index was created, and `SEARCH` may require one that isn't documented in the image's `--help`, which only covers server/CLI subcommands, not SQL syntax). **Flag for whichever task actually implements vector-search decoding: re-verify SEARCH's real result shape before writing a decoder for it — this spike could not produce a non-empty result to base a decoder on.**

## ErrorResponse sample

The brief's specified probe, `SELECT nonexistent_fn()`, **did NOT produce an ErrorResponse** — surprising deviation from Postgres semantics:

```
RowDescription:
  name='nonexistent_fn()' type_oid=25 type_len=0 type_mod=0 format_code=0
DataRow:
  raw_bytes=None
CommandComplete: b'SELECT 1\x00'
```

NodeDB 0.4.0 evaluates a call to an unknown function as a successful query returning one row with a single `NULL` (text/OID 25) column, rather than raising `42883 function does not exist` the way Postgres does. (`SELECT 1/0` behaves the same way — a successful `NULL` result, not a division-by-zero error.) **Neither can be used as the ErrorResponse sample the brief needs**, so a substitute genuine error was captured instead:

Substitute query: `SELECT * FROM nonexistent_table_xyz`

Raw `ErrorResponse` fields (from the wire probe):

```
S='ERROR'
C='42P01'
M='collection "nonexistent_table_xyz" does not exist'
```

- `S` (severity): `ERROR`
- `C` (SQLSTATE code): `42P01` (Postgres-standard "undefined_table" code, reused here for "collection does not exist")
- `M` (message, verbatim): `collection "nonexistent_table_xyz" does not exist`

Only these three fields (`S`, `C`, `M`) were present in the `ErrorResponse` — no `D` (Detail), `H` (Hint), `P` (Position), or other optional Postgres error fields were sent. Confirmed on two other error samples too (syntax error, unique-constraint violation) — all three also carried only `S`/`C`/`M`:

```
# SELEKT 1  (syntax error)
S='ERROR' C='42601' M='parse error: sql parser error: Expected: an SQL statement, found: SELEKT at Line: 1, Column: 1'

# duplicate primary key insert
S='ERROR' C='XX000' M='dispatch error: raft propose failed: dispatch error: apply error: internal error: RejectedConstraint { constraint: "unique", detail: "duplicate key value \'a\' violates primary-key uniqueness on \'spike_t\'" }'
```

**Task 15 (error decoding) should assume only S/C/M are populated** — do not build a decoder that requires optional Postgres error fields to be present.

## Other CommandComplete tags observed (bonus — useful for a general dispatcher)

Captured via the raw wire probe for cross-reference:

| Statement | CommandComplete tag (raw) |
|---|---|
| `CREATE COLLECTION ...` | `CREATE COLLECTION` |
| `INSERT INTO ...` | `OK` (not Postgres's `INSERT 0 1`) |
| `DROP COLLECTION ...` | `DROP COLLECTION` |
| `SELECT ...` (normal) | `SELECT <n>` (Postgres-standard) |
| `SEARCH ...` | `SELECT 0` (see SEARCH section above) |

**`DROP COLLECTION` is a soft-delete with a retention window**, discovered incidentally: after dropping `spike_t`, querying it again returned:
```
ERROR:  collection "spike_t" was dropped and is within its retention window; restore it with `UNDROP COLLECTION spike_t` before it is hard-deleted
```
Not required by the brief's template, but worth knowing for any later task that drops/recreates collections by the same name within one container's lifetime — reuse a fresh name (e.g. `spike_t2`) if a truly-gone collection is needed, or issue `UNDROP COLLECTION <name>` first.

## Structured summary (per brief's template)

```markdown
- Docker: farhansyah/nodedb:0.4.0 (digest sha256:e29309aeb3c8e83070a9e0ee276fb6df178263aa782819cd928c830b4cac3ae4)
- Connect: host=localhost port=16432 user=nodedb dbname=nodedb auth=scram-sha-256 password=CpUb8WB8XRncTHmuKZPTfovE
- server_version: "15.0 (NodeDB 0.4.0)"
- OIDs observed: id=25 n=20 f=701 b=16 ts=1114 emb=25 (emb is TEXT-typed JSON, not a native array/vector OID — see Vector text below)
- Timestamp text: "2026-07-23 10:00:00"
- Vector text: "[\"0.1\",\"0.2\",\"0.3\"]" (JSON array of quoted strings — NOT pg-standard "{0.1,0.2,0.3}")
- ErrorResponse fields: S=ERROR C=42P01 M=collection "nonexistent_table_xyz" does not exist
```
