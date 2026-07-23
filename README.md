# nodedb.cr

[![CI](https://github.com/emanzx/nodedb.cr/actions/workflows/ci.yml/badge.svg)](https://github.com/emanzx/nodedb.cr/actions/workflows/ci.yml)

A Crystal client for [NodeDB](https://github.com/NodeDB-Lab/nodedb), the
multi-model (relational, vector, graph, full-text, timeseries, spatial, KV)
storage engine that speaks the PostgreSQL wire protocol. It registers a
`nodedb://` driver with [crystal-db](https://github.com/crystal-lang/crystal-db)
and ports the SQL-builder API of [nodedb-ruby](https://github.com/mkhairi/nodedb-ruby),
NodeDB's Ruby client, so the two clients read as one family.

## Installation

```yaml
dependencies:
  nodedb:
    github: emanzx/nodedb.cr
    version: ~> 0.1.0
```

```
shards install
```

## Quick start

```crystal
require "db"
require "nodedb"

DB.open("nodedb://nodedb:password@localhost:6432/nodedb") do |db|
  db.exec NodeDB::SQL::Collection.create("notes",
    columns: ["id TEXT PRIMARY KEY", "body TEXT", "views INT"])

  db.exec "INSERT INTO notes (id, body, views) VALUES ($1, $2, $3)",
    "n1", "hello nodedb", 3

  db.query("SELECT id, body, views FROM notes") do |rs|
    rs.each do
      # NodeDB's INT DDL keyword is 8-byte on the wire (OID 20) — read
      # as Int64, not Int32.
      puts "#{rs.read(String)}: #{rs.read(String)} (#{rs.read(Int64)} views)"
    end
  end
  # => n1: hello nodedb (3 views)

  db.exec NodeDB::SQL::Collection.drop_if_exists("notes")
end
```

**Gotcha:** unaliased/computed expressions (e.g. `SELECT 1+1`) come back as
OID 25 (text), not a numeric OID — decode `as: String` and parse yourself:

```crystal
db.query_one("SELECT 1+1", as: String).to_i # => 2
```

## Vector search

`SEARCH ... USING VECTOR(...)` returns nothing until a vector index exists
over the target column — this is the one builder module that needs the full
flow to actually work, so here it is end to end:

```crystal
require "db"
require "nodedb"

DB.open("nodedb://nodedb:password@localhost:6432/nodedb") do |db|
  db.exec NodeDB::SQL::Collection.create("articles",
    columns: ["id TEXT PRIMARY KEY", "embedding FLOAT[]"])

  # Required before SEARCH returns any rows. Uses the "(column)" form with
  # a space before the paren — the only binding syntax NodeDB 0.4.0 honors.
  db.exec NodeDB::SQL::Vector.create_index(
    name: "articles_embedding_idx", table: "articles",
    column: "embedding", dim: 3)

  db.exec "INSERT INTO articles (id, embedding) VALUES ($1, $2)",
    "intro", [0.1, 0.2, 0.3] of Float64
  db.exec "INSERT INTO articles (id, embedding) VALUES ($1, $2)",
    "outro", [0.9, 0.9, 0.9] of Float64

  sql = NodeDB::SQL::Vector.search(table: "articles", column: "embedding",
    embedding: [0.1, 0.2, 0.3] of Float64, limit: 1)
  db.query(sql) { |rs| rs.each { puts rs.read(String) } }
  # => intro

  # FLOAT[] (vector) columns arrive as OID 25 text containing JSON
  # (e.g. ["0.1","0.2","0.3"]), not a native array/vector wire type —
  # read as String, then parse with TypeMap.parse_vector.
  db.query("SELECT embedding FROM articles WHERE id = $1", "intro") do |rs|
    rs.each { puts NodeDB::TypeMap.parse_vector(rs.read(String)) }
  end
  # => [0.1, 0.2, 0.3]

  db.exec NodeDB::SQL::Vector.drop_index("articles_embedding_idx")
  db.exec NodeDB::SQL::Collection.drop_if_exists("articles")
end
```

## Other builders

The remaining builder modules are pure SQL-string generators — they never
touch a connection, so these examples run standalone (`require "nodedb"`,
no `DB.open` needed):

**Graph** — node/edge insert + traversal:

```crystal
NodeDB::SQL::Graph.insert_edge(
  in_collection: "social_nodes",
  from: "alice", to: "bob", type: "knows",
  properties: {"since" => 2020} of String => NodeDB::SQL::Graph::PropValue)
# => GRAPH INSERT EDGE IN social_nodes FROM 'alice' TO 'bob' TYPE 'knows' PROPERTIES '{"since":2020}'

NodeDB::SQL::Graph.traverse(from: "alice", depth: 2)
# => GRAPH TRAVERSE FROM 'alice' DEPTH 2
```

`GRAPH TRAVERSE` has no collection-scoping clause — it walks a
database-global node/edge space and returns one row with one JSON column
(`{"nodes":[...],"edges":[...]}`), not one row per node. See
[docs/wire-facts.md](docs/wire-facts.md) for the verified live shape.

**FTS** — full-text search over `text_match()`:

```crystal
NodeDB::SQL::FTS.create_index(name: "posts_body_idx", collection: "posts", column: "body")
# => CREATE FULLTEXT INDEX posts_body_idx ON posts (body)

NodeDB::SQL::FTS.search(table: "posts", column: "body", query: "machine learning", limit: 20)
# => SELECT id FROM posts WHERE text_match(body, 'machine learning') LIMIT 20
```

**KV** — key/value TTL updates:

```crystal
NodeDB::SQL::KV.set_ttl(table: "sessions", key: "user:1", ttl: 3600)
# => UPDATE sessions SET ttl = 3600 WHERE key = 'user:1'
```

**Timeseries** — bucketing and epoch-ms range clauses:

```crystal
NodeDB::SQL::Timeseries.time_bucket("1h")
# => time_bucket('1h', timestamp) AS bucket

NodeDB::SQL::Timeseries.since_clause(Time.utc(2026, 7, 23, 5, 0, 0))
# => timestamp > 1784782800000
```

**Spatial** — `ST_*` expression builders (`ST_Point` takes lon, lat):

```crystal
NodeDB::SQL::Spatial.within_distance(column: "geom", lat: 3.15, lon: 101.7, meters: 500.0)
# => ST_DWithin(geom, ST_Point(101.7, 3.15), 500.0)
```

**Collection** — DDL, including per-engine default columns:

```crystal
NodeDB::SQL::Collection.create("metrics", engine: "timeseries",
  engine_options: {"retention" => "7d"})
# => CREATE COLLECTION metrics (ts TIMESTAMP TIME_KEY, value FLOAT) WITH (engine='timeseries', retention='7d')
```

## Schema introspection

`NodeDB::Schema` wraps `DESCRIBE` / `SHOW COLLECTIONS` with typed columns:

```crystal
NodeDB::Schema.columns(db, "articles") # => Array(NodeDB::Schema::Column) (name, type, pg_type, oid, nullable, primary_key)
NodeDB::Schema.collections(db)         # => Array(String)
```

## Compatibility

- **NodeDB >= 0.4.0 required.** 0.3.0 silently drops bind parameters and
  reports OID 25 (text) for every column — pathologically false-pass-friendly,
  not just "missing a feature". `nodedb.cr` runs `SHOW server_version` at
  connect time and prints a stderr warning (not a raise) if the server
  reports below 0.4.0.
- **pgwire simple query protocol only** (v1). No Parse/Bind/Describe/Execute
  — `nodedb.cr` owns a minimal pgwire client rather than wrapping crystal-pg,
  because crystal-pg has no simple-query result path and mis-decodes
  NodeDB's text-downgraded types (see the design spec's "Why not crystal-pg"
  section).
- **`$n` args are inlined client-side** through `NodeDB::SQL::Quoting` before
  the SQL string ever reaches the wire — there is no real bind protocol
  underneath. **Caveat:** substitution is a regex pass over the whole SQL
  string, so a literal `$1`-shaped token *inside a string literal* would also
  get substituted. Keep placeholders out of string literals.
- **Auth: trust and SCRAM-SHA-256.** These are the only two mechanisms
  NodeDB 0.4.0 offers (no md5/cleartext); `nodedb.cr` implements a full
  RFC 5802 SCRAM-SHA-256 handshake.
- **Known dialect quirks** (all captured live in
  [docs/wire-facts.md](docs/wire-facts.md)):
  - Unaliased/computed expressions (`SELECT 1+1`) arrive as OID 25 text, not
    a numeric OID.
  - `INT` DDL columns are 8-byte on the wire (OID 20) — decode `as: Int64`.
  - `FLOAT[]` (vector) columns arrive as OID 25 text containing a JSON array
    of stringified floats, not a native array/vector wire type — parse with
    `NodeDB::TypeMap.parse_vector`.
  - `SEARCH` needs a vector index bound with `NodeDB::SQL::Vector.create_index`'s
    `(column)` form (space before the paren) — `FIELD column` and `(column)`
    without the space both parse but silently no-op.
  - `DROP INDEX` on a vector index reports success but does not remove it
    from `SHOW INDEXES` — best-effort cleanup only.
  - `DROP COLLECTION` is a soft delete with a retention window: querying a
    just-dropped collection name raises instead of "does not exist"
    (recreating it fresh with `CREATE COLLECTION` works immediately).
  - `ErrorResponse` only ever populates `S`/`C`/`M` (severity/sqlstate/message)
    — no Detail/Hint/Position.
  - `GRAPH TRAVERSE` is database-global, not collection-scoped (see above).

## Roadmap

- Native MessagePack transport (`:6433`).
- `LISTEN`/`NOTIFY`.
- Extended query protocol (real parameterized queries — NodeDB 0.4.0
  supports it upstream; the simple-query client is deliberately the v1
  starting point, not a ceiling).
- ORM adapter shards (Granite, Jennifer).

## Development

```bash
docker run -d --name nodedb-dev -p 6432:6432 \
  -e NODEDB_SUPERUSER_PASSWORD=devpassword \
  farhansyah/nodedb:0.4.0

shards install
crystal spec                                                  # unit specs, no server needed
crystal tool format --check src spec

NODEDB_URL=nodedb://nodedb:devpassword@localhost:6432/nodedb \
  crystal spec --tag integration                              # against the running container
```

See [docs/wire-facts.md](docs/wire-facts.md) and
[.github/workflows/ci.yml](.github/workflows/ci.yml) for the exact
container/credentials mechanism CI uses (the image ships no default
credentials and regenerates a random superuser password on every boot
unless `NODEDB_SUPERUSER_PASSWORD` is set).

## License

BSD-2-Clause. See [LICENSE](LICENSE).

API design follows [nodedb-ruby](https://github.com/mkhairi/nodedb-ruby) by
[@mkhairi](https://github.com/mkhairi).
