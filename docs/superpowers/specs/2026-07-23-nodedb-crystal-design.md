# nodedb.cr — Design Spec

**Date:** 2026-07-23 (rev 2 — post adversarial review)
**Repo:** `github.com/emanzx/nodedb.cr` · shard name `nodedb`
**License:** BSD-2-Clause (family parity with [nodedb-ruby](https://github.com/mkhairi/nodedb-ruby))
**Status:** Approved design revised after adversarial review; pre-implementation

## Purpose

A Crystal client for [NodeDB](https://github.com/NodeDB-Lab/nodedb) — the multi-model
memory/storage engine (relational, vector, graph, FTS, timeseries, spatial, KV, arrays).
This is the Crystal sibling of Khairi's `nodedb-ruby`: same concepts, same module map,
same transport philosophy — adapted to Crystal idiom.

Contribution goal: give the crystal-lang community a first-class NodeDB client, and give
the NodeDB client family a third language (Rust, Ruby, Crystal).

## Reference implementations

- **API shape:** `mkhairi/nodedb-ruby` — `NodeDB::Connection`, `NodeDB::SQL::*` builders,
  transport-agnostic SQL strings. Its sql+core spec corpus (69 examples) seeds our
  builder specs.
- **SQL dialect + wire truth:** NodeDB v0.4.0 source (local checkout `nodedb-040`:
  `nodedb-sql` for dialect, `nodedb/src/control/server/pgwire/` for wire behavior).
  Do not invent syntax; do not trust README folklore — rev 1 of this spec inherited a
  stale limitation from nodedb-ruby's README that the 0.4.0 source refutes.
- **Minimum supported server: NodeDB 0.4.0.** 0.3.0 silently drops extended-protocol
  bind parameters and reports OID 25 (text) for every column — pathologically
  false-pass-friendly. The driver SHOULD check `SHOW server_version` at connect and warn
  below 0.4.0.

## Architecture

Two layers, mirroring nodedb-ruby's split, with crystal-db as the standard API seam:

```
┌─────────────────────────────────────────────────┐
│  ORMs (Granite, Jennifer, Avram)                │   ← future; each needs its own
├─────────────────────────────────────────────────┤     hand-written adapter shard
│  crystal-db (DB.open "nodedb://...")            │   ← standard API, pooling
├────────────────────────┬────────────────────────┤
│  NodeDB::Driver        │  NodeDB::SQL builders  │   ← this shard
│  + NodeDB::Wire        │  (pure SQL strings)    │
│  (own pgwire client)   │                        │
├────────────────────────┴────────────────────────┤
│  NodeDB Origin server (pgwire :6432)            │
└─────────────────────────────────────────────────┘
```

Key property carried over from nodedb-ruby: **builders return plain SQL strings** and know
nothing about transports. When the native MessagePack transport lands (v2), every builder
works unchanged.

### Why not crystal-pg (adversarial review, 2026-07-23)

Rev 1 planned to wrap crystal-pg. Two refuting findings, both verified in source:

1. **No simple-query path.** crystal-pg's prepared and "unprepared" statements both send
   Parse/Bind/Describe/Execute (extended protocol); `prepared_statements=false` changes
   nothing on the wire, and its `PQ::SimpleQuery` discards all result frames. Ruby's `pg`
   works because `PQexec` is genuinely simple-protocol; crystal-pg has no equivalent.
2. **Binary/text decode mismatch.** crystal-pg requests binary result format and selects
   decoders by OID while ignoring the per-column format flag the server returns. NodeDB
   0.4.0 downgrades Timestamp/Numeric/Json and **all array types (vectors included)** to
   text even when binary is requested → mis-decoded garbage on the marquee feature.

A fork/monkeypatch of crystal-pg's decode layer would tie us to its internals. A minimal
pgwire client we own is the cleaner shard.

## Components

### `NodeDB::Wire` (pgwire client, owned by this shard)

Minimal PostgreSQL wire-protocol client, pure Crystal, ~the scope of what nodedb-ruby
gets from libpq:

- **v1: simple query protocol only** (`Q` message). Startup, auth, query, result decode,
  error mapping. Parameters are inlined through the quoting layer (exactly nodedb-ruby's
  `conn.exec` model).
- **Text result format**, decoding driven by the RowDescription **per-column format flag
  honored** (the thing crystal-pg skips) + OID.
- **Auth: trust + SCRAM-SHA-256.** NodeDB 0.4.0 offers only these (no md5/cleartext), so
  SCRAM is v1-mandatory, not optional polish.
- Extended protocol (real parameterized queries) is a designed-for v1.x addition — 0.4.0
  supports it fully; we start simple because it's the smaller correct core, not because
  upstream can't.

### `NodeDB::Driver` (crystal-db driver)

- Registers scheme `nodedb://` with crystal-db; implements `DB::Driver` /
  `DB::Connection` / `DB::Statement` / `DB::ResultSet` over `NodeDB::Wire`.
- Pooling comes free from crystal-db (`initial_pool_size` etc.).
- Default port 6432. `database`/`user` are required (nodedb-ruby requires them too — rev 1
  wrongly claimed it had defaults).
- What crystal-db registration buys: standard API + pooling + drop-in familiarity. It does
  **not** make ORMs work by itself — Granite/Jennifer/Avram each dispatch on registered
  adapter classes with hand-coded dialect/DDL, so each needs its own adapter shard (later,
  out of scope, same as nodedb-ruby's `activerecord-nodedb-adapter` plan).

### `NodeDB::SQL` builder modules

Same module map as nodedb-ruby — concepts and docs transfer 1:1:

| Module | Covers |
|---|---|
| `NodeDB::SQL::Vector` | similarity search over embeddings |
| `NodeDB::SQL::Graph` | node/edge insert, traversal, algorithms (PageRank) |
| `NodeDB::SQL::FTS` | full-text `text_match()` search |
| `NodeDB::SQL::KV` | get/set key-value ops |
| `NodeDB::SQL::Timeseries` | `time_bucket` aggregation |
| `NodeDB::SQL::Spatial` | distance queries |
| `NodeDB::SQL::Collection` | collection DDL (create/convert/typeguards) |

**Crystal-idiomatic divergence (deliberate):** builders take typed arguments; **values**
are escaped/serialized internally (`from: "alice"`, not `from: "'alice'"`).
**Identifiers** (table/column names) are *validated against a strict pattern*
(`[A-Za-z_][A-Za-z0-9_]*`) and interpolated unquoted — NOT double-quoted: NodeDB's
`SEARCH` rejects quoted identifiers (nodedb-ruby documented quirk), so quoting would
silently break Vector.search. Invalid identifiers raise `ArgumentError` at build time.
All escaping/validation lives in one place (`NodeDB::SQL::Quoting`).

```crystal
NodeDB::SQL::Vector.search(
  table: "articles", column: "embedding",
  embedding: [0.1, 0.2, 0.3], limit: 10
)

NodeDB::SQL::Graph.insert_edge(
  in_collection: "social_nodes",
  from: "alice", to: "bob", type: "knows",
  properties: {"since" => 2020}
)
```

### `NodeDB::Schema`

Introspection helpers (list collections, describe engine types) — ported from
nodedb-ruby's `NodeDB::Schema`. NodeDB emulates a `pg_type` catalog; use what the server
actually serves, verified in integration specs.

### `NodeDB::TypeMap`

Text-format decode of NodeDB's types on top of `NodeDB::Wire`:

- Vectors: NodeDB emits **both** Float4Array (OID 1021) and Float8Array (OID 1022) →
  `Array(Float32)` / `Array(Float64)`, both supported.
- JSON documents → `JSON::Any`; timestamps → `Time`; unknown OIDs fall back to `String`,
  never raise.

## v1 scope

**In:** own pgwire client (simple query, trust+SCRAM auth) · crystal-db driver
registration · all seven builder modules · `Schema` + `TypeMap` · builder spec corpus +
env-gated integration specs · README with usage examples mirroring nodedb-ruby's ·
GitHub Actions CI.

**Out (explicit, all deliberate v2+ — none are upstream gaps):**
- Extended protocol / real parameterized queries (0.4.0 supports it; v1.x addition).
- Native MessagePack transport (:6433).
- LISTEN/NOTIFY (0.4.0 supports it; needs async notification reading in Wire — v2).
- ORM adapter shards — separate repos, later.
- Streaming / LIVE SELECT · TLS/channel-binding SCRAM variants.

## Risks

1. **Wire drift between NodeDB minors.** Observed 0.3.0→0.4.0: all-text OIDs → typed
   OIDs; dropped bind params → AST-bound. Upstream declares protocols frozen through 1.0,
   but design defensively: pin the CI image to a specific tag, gate on `server_version`
   at connect, keep decoders tolerant (unknown OID → String).
2. **SCRAM correctness.** Hand-rolling SCRAM-SHA-256 is the trickiest Wire piece; test
   against a SCRAM-enabled 0.4.0 container in CI, not just trust-mode.
3. **Text serialization of 0.4.0 vector columns** — not yet observed live (review ran
   against 0.3.0 read-only). Verified first in the spike.

## Error handling

- `NodeDB::Error < DB::Error` hierarchy; pgwire `ErrorResponse` mapped with NodeDB's
  message/code preserved.
- Connection-refused / auth failures surface as crystal-db's standard connection errors.
- Builders raise `ArgumentError` on invalid input (bad identifier, empty embedding,
  non-positive limit) at build time — fail before the wire, not on it.

## Testing

- **Builder specs:** pure string assertions, no server required. Seed by porting
  nodedb-ruby's spec corpus; every builder module gets escaping/injection cases
  (quotes in values, unicode, empty inputs, identifier-validation rejections).
- **Integration specs:** gated behind `NODEDB_URL`; skipped when unset. Dev + CI run
  `farhansyah/nodedb` **pinned 0.4.0 tag** (the box's long-running instance is 0.3.0 —
  below minimum; do not test against it).
- **Spike checklist (step 1, against 0.4.0 docker):** typed-column reads that prove
  decode correctness — int, timestamp, and a vector column round-trip (create collection,
  insert, search) — plus a SCRAM login. A bare `SELECT 1+1` proves nothing (0.3.0
  false-passes it).
- **CI:** latest stable Crystal + pinned docker service; `crystal spec` +
  `crystal tool format --check`.

## Milestones

1. Toolchain + spike: install crystal, run 0.4.0 docker, execute the spike checklist
   with a throwaway script (raw socket or `psql`) to lock wire facts.
2. Shard skeleton (`shards init`, license, CI, README stub).
3. `NodeDB::Wire`: startup/auth (trust+SCRAM) → simple query → RowDescription/DataRow
   decode → error mapping. Spec-first against the docker instance.
4. `NodeDB::Driver`: crystal-db registration over Wire.
5. Builders (Vector → Graph → FTS → KV → Timeseries → Spatial → Collection), spec-first,
   `Quoting` + identifier validation first.
6. Schema + TypeMap.
7. README + examples + shards.yml polish → tag v0.1.0, announce (Crystal forum,
   shardbox.org, NodeDB Discord).

## Decisions log

| Decision | Choice | Why |
|---|---|---|
| Shape | Port of nodedb-ruby, crystal-idiomatic | Khairi's design is proven; crystal-db is Crystal's standard seam |
| Naming | `emanzx/nodedb.cr`, shard `nodedb` | eman's call, crystal-flavored repo name |
| Transport v1 | **Own pgwire client, simple query** | Adversarial review 2026-07-23: crystal-pg has no simple-query result path AND mis-decodes NodeDB's text-downgraded types (binary-by-OID, format flag ignored). Wrapping refuted; owning the wire is cleaner than forking |
| Min server | NodeDB 0.4.0 | 0.3.0 drops bind params silently + all-text OIDs; extended protocol + typed OIDs land in 0.4.0 |
| Quoting | Values escaped internally; identifiers validated (allowlist), unquoted | Type safety without the pre-quoted-args footgun; NodeDB `SEARCH` rejects quoted identifiers |
| License | BSD-2-Clause | Match nodedb-ruby — the clients read as a family |
| Pooling | crystal-db's | Free, standard, battle-tested |
| ORM story | Per-ORM adapter shards, later | Review: Granite/Jennifer/Avram all need hand-written adapters; crystal-db buys API+pooling only |
