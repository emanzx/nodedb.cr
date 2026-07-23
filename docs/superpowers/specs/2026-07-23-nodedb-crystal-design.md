# nodedb.cr — Design Spec

**Date:** 2026-07-23
**Repo:** `github.com/emanzx/nodedb.cr` · shard name `nodedb`
**License:** BSD-2-Clause (family parity with [nodedb-ruby](https://github.com/mkhairi/nodedb-ruby))
**Status:** Approved design, pre-implementation

## Purpose

A Crystal client for [NodeDB](https://github.com/NodeDB-Lab/nodedb) — the multi-model
memory/storage engine (relational, vector, graph, FTS, timeseries, spatial, KV, arrays).
This is the Crystal sibling of Khairi's `nodedb-ruby`: same concepts, same module map,
same transport philosophy — adapted to Crystal idiom.

Contribution goal: give the crystal-lang community a first-class NodeDB client, and give
the NodeDB client family a third language (Rust, Ruby, Crystal).

## Reference implementations

- **API shape:** `mkhairi/nodedb-ruby` — `NodeDB::Connection`, `NodeDB::SQL::*` builders,
  transport-agnostic SQL strings. Its spec corpus (~69 examples) seeds our builder specs.
- **SQL dialect:** NodeDB v0.4.0 (2026-07-19). Wire protocols are frozen-stable through
  1.0. Local source checkout at `/home/system/rnd/nodedb-040` (see `nodedb-sql` crate +
  `docs/` engine guides) is the dialect authority. Do not invent syntax — port it from
  nodedb-ruby's builders and verify against the nodedb docs/live server.
- **Wire transport:** `will/crystal-pg` — pure-Crystal PostgreSQL wire protocol,
  registered crystal-db driver. Plays the role the `pg` gem plays for nodedb-ruby.

## Architecture

Two layers, mirroring nodedb-ruby's split, with crystal-db as the framework-agnostic seam:

```
┌─────────────────────────────────────────────────┐
│  ORMs / frameworks (Granite, Jennifer, Avram)   │   ← future, mostly free via crystal-db
├─────────────────────────────────────────────────┤
│  crystal-db (DB.open "nodedb://...")            │   ← stdlib-adjacent standard API
├────────────────────────┬────────────────────────┤
│  NodeDB::Driver        │  NodeDB::SQL builders  │   ← this shard
│  (pgwire via pg shard) │  (pure SQL strings)    │
├────────────────────────┴────────────────────────┤
│  NodeDB Origin server (pgwire :6432)            │
└─────────────────────────────────────────────────┘
```

Key property carried over from nodedb-ruby: **builders return plain SQL strings** and know
nothing about transports. When the native MessagePack transport lands (v2), every builder
works unchanged.

## Components

### `NodeDB::Driver` (crystal-db driver)

- Registers scheme `nodedb://` with crystal-db.
- Delegates the wire work to crystal-pg's protocol machinery (rewrites the URI to the
  postgres scheme internally, forwards connection options).
- **Forces simple query protocol** (`prepared_statements=false` by default). NodeDB's
  pgwire cannot serve extended-protocol prepares (no `RowDescription` for them — the same
  upstream limitation nodedb-ruby documents). Attempting to enable prepared statements is
  an error until upstream supports it.
- Default port 6432; sensible defaults matching nodedb-ruby (`dbname=nodedb`, `user=nodedb`).

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

**Crystal-idiomatic divergence (deliberate):** builders take typed arguments and quote /
escape / JSON-serialize internally. Where ruby callers write `from: "'alice'"`, Crystal
callers write `from: "alice"`. Example target API:

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

Escaping rules live in one place (`NodeDB::SQL::Quoting`), used by every builder.

### `NodeDB::Schema`

Introspection helpers (list collections, describe engine types) — ported from
nodedb-ruby's `NodeDB::Schema`, over whatever introspection SQL NodeDB exposes.

### `NodeDB::TypeMap`

NodeDB-specific result conversions (vector columns ↔ `Array(Float64)`, JSON documents ↔
`JSON::Any`), layered on crystal-db's result-set decoding.

### Pooling

Not ported. crystal-db provides pooling natively (`initial_pool_size`, `max_pool_size`
URI params) — `NodeDB::Pool` has no Crystal equivalent to build.

## v1 scope

**In:** pgwire transport · all seven builder modules · crystal-db driver registration ·
`Schema` + `TypeMap` · builder spec corpus + env-gated integration specs · README with
usage examples mirroring nodedb-ruby's · GitHub Actions CI.

**Out (explicit):**
- Native MessagePack transport (:6433) — v2; the string-builder seam already supports it.
- LISTEN/NOTIFY, prepared statements — upstream gaps, tracked not worked around.
- ORM adapter shards (`granite-adapter-nodedb`, …) — later, separate repos, exactly like
  nodedb-ruby's `activerecord-nodedb-adapter` plan.
- Streaming / LIVE SELECT.

## Primary risk — spiked before any structure is built

crystal-pg may issue postgres catalog queries (`pg_type` etc.) at connect time that
NodeDB's pgwire does not implement.

**Spike (implementation step 1, ~30 min):** raw `crystal-pg` `DB.open` against a live
Origin instance (local dev instance, `$NODEDB_URL`), run `SELECT 1+1`, a vector query,
and a result-set decode.

- **Pass →** proceed with the wrap-crystal-pg design.
- **Fail →** fallback: minimal pure-Crystal simple-query pgwire client inside this shard
  (startup/auth, simple Query, RowDescription/DataRow decode, error mapping). Moderate,
  well-understood work; removes the crystal-pg dependency entirely. The builder layer and
  crystal-db registration are unaffected either way.

## Error handling

- `NodeDB::Error < DB::Error` hierarchy; pgwire `ErrorResponse` mapped with NodeDB's
  message/code preserved.
- Connection-refused / auth failures surface as crystal-db's standard connection errors.
- Builders raise `ArgumentError` on invalid input (empty embedding, non-positive limit)
  at build time — fail before the wire, not on it.

## Testing

- **Builder specs:** pure string assertions, no server required. Seed by porting
  nodedb-ruby's spec corpus; every builder module gets escaping/injection cases
  (quotes in values, unicode, empty inputs).
- **Integration specs:** gated behind `NODEDB_URL` env var; skipped when unset. Dev runs
  point at a local Origin instance; CI runs `farhansyah/nodedb:latest` as a GitHub Actions
  service container.
- **CI:** latest stable Crystal + the docker service; `crystal spec` + `crystal tool format --check`.

## Milestones

1. Toolchain + spike (crystal install, raw crystal-pg vs live NodeDB).
2. Shard skeleton (`shards init`, license, CI, README stub).
3. Driver layer (nodedb:// registration, simple-query enforcement, error mapping).
4. Builders (Vector → Graph → FTS → KV → Timeseries → Spatial → Collection), spec-first.
5. Schema + TypeMap.
6. README + examples + shards.yml polish → tag v0.1.0, announce (Crystal forum,
   shardbox.org, NodeDB Discord).

## Decisions log

| Decision | Choice | Why |
|---|---|---|
| Shape | Port of nodedb-ruby, crystal-idiomatic | Khairi's design is proven; crystal-db registration is Crystal's framework-agnostic seam |
| Naming | `emanzx/nodedb.cr`, shard `nodedb` | eman's call, crystal-flavored repo name |
| Transport v1 | pgwire only | nodedb-ruby's `:pg` is primary too; native has known transactional limits |
| Quoting | Internal, typed args | Type safety is the point of Crystal; pre-quoted args are injection-prone |
| License | BSD-2-Clause | Match nodedb-ruby — the clients read as a family |
| Pooling | crystal-db's | Free, standard, battle-tested |
