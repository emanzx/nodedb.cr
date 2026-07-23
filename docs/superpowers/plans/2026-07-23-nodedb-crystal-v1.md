# nodedb.cr v0.1.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `nodedb.cr` v0.1.0 — a Crystal client for NodeDB with an owned pgwire client (simple query protocol), crystal-db driver registration, and the seven `NodeDB::SQL` builder modules ported from nodedb-ruby.

**Architecture:** Two layers per the approved spec (`docs/superpowers/specs/2026-07-23-nodedb-crystal-design.md`): `NodeDB::Wire` (minimal pure-Crystal pgwire client: startup, trust+SCRAM-SHA-256 auth, simple `Q` queries, text results honoring per-column format flags) under a crystal-db driver (`nodedb://` scheme); beside it, pure SQL-string builder modules that know nothing about transports. Builders are ported byte-faithful from nodedb-ruby's `lib/nodedb/sql/*.rb` (cloned reference at `<scratchpad>/nodedb-ruby`; SQL shapes are reproduced in each task below, so the clone is optional).

**Tech Stack:** Crystal ≥ 1.14, `crystal-db ~> 0.13`, OpenSSL stdlib (SCRAM), Docker `farhansyah/nodedb` (0.4.0 tag) for integration tests, GitHub Actions CI.

## Global Constraints

- Repo: `github.com/emanzx/nodedb.cr` · shard name `nodedb` · License BSD-2-Clause.
- Minimum supported server: **NodeDB 0.4.0**. Never test against the box's long-running 0.3.0 instance (it silently drops bind params and reports OID 25 everywhere). Integration target is always the pinned-tag docker container on **port 16432** (avoids any collision with the box instance).
- Wire: **simple query protocol only** (`Q`). Text result decoding driven by RowDescription per-column **format flag + OID**; unknown OID decodes to `String`, never raises.
- Identifiers are validated against `/\A[A-Za-z_][A-Za-z0-9_]*\z/` and interpolated **unquoted** (NodeDB `SEARCH` rejects quoted identifiers). Values are escaped/serialized by `NodeDB::SQL::Quoting` only — escaping logic lives nowhere else.
- Only runtime dependency: `crystal-db`. No crystal-pg, no msgpack.
- TDD every task: failing spec first, then code. Before every commit: `crystal spec` green AND `crystal tool format --check src spec` clean.
- Builder SQL must match the shapes documented in each task (ported from nodedb-ruby) exactly — they encode live dialect quirks (e.g. `SEARCH ... USING VECTOR`, `GRAPH INSERT EDGE IN`, `engine: fts → document_strict`).
- Facts discovered in Task 1 land in `docs/wire-facts.md`; later tasks cite it instead of re-probing.

---

### Task 1: Toolchain, 0.4.0 container, wire-facts spike

**Files:**
- Create: `docs/wire-facts.md`

**Interfaces:**
- Produces: a running NodeDB 0.4.0 container on `localhost:16432`; `docs/wire-facts.md` recording (a) docker tag pinned, (b) auth mode + credentials, (c) `SHOW server_version` output, (d) OIDs and text serialization for int/float/bool/timestamp/vector columns, (e) timestamp text format, (f) ErrorResponse sample. Tasks 10–15 consume these facts.

- [ ] **Step 1: Install Crystal + verify**

```bash
curl -fsSL https://crystal-lang.org/install.sh | sudo bash
crystal --version && shards --version
```
Expected: `Crystal 1.x` (≥ 1.14).

- [ ] **Step 2: Install psql client if missing**

```bash
psql --version || sudo apt-get install -y postgresql-client
```

- [ ] **Step 3: Find and pin the 0.4.0 docker tag**

```bash
curl -s "https://hub.docker.com/v2/repositories/farhansyah/nodedb/tags?page_size=100" \
  | jq -r '.results[].name' | sort -V
```
Pick the exact 0.4.0 tag (e.g. `0.4.0`; if only `latest` exists, resolve its digest with `docker manifest inspect` and pin the digest). Record the chosen reference in `docs/wire-facts.md`.

- [ ] **Step 4: Run the container**

```bash
docker run -d --name nodedb-test -p 16432:6432 farhansyah/nodedb:<PINNED_TAG>
sleep 3 && docker logs nodedb-test | tail -20
```
Read the logs for the default user/database/auth mode. Try in order until one connects, and record the winner:

```bash
psql "host=localhost port=16432 user=nodedb dbname=nodedb" -c "SELECT 1"
psql "host=localhost port=16432 user=postgres dbname=postgres" -c "SELECT 1"
```
If a password is required (SCRAM), find it in the image docs/logs (`docker inspect farhansyah/nodedb:<PINNED_TAG> | jq '.[0].Config.Env'`).

- [ ] **Step 5: Run the spike checklist and record every output in `docs/wire-facts.md`**

```bash
PSQL='psql "host=localhost port=16432 user=<USER> dbname=<DB>" -c'
$PSQL "SHOW server_version"                                   # must say 0.4.x
$PSQL "CREATE COLLECTION spike_t (id TEXT PRIMARY KEY, n INT, f FLOAT, b BOOLEAN, ts TIMESTAMP, emb FLOAT[])"
$PSQL "INSERT INTO spike_t (id, n, f, b, ts, emb) VALUES ('a', 42, 1.5, true, '2026-07-23 10:00:00', ARRAY[0.1, 0.2, 0.3])"
$PSQL "SELECT id, n, f, b, ts, emb FROM spike_t"
$PSQL "SEARCH spike_t USING VECTOR(emb, ARRAY[0.1, 0.2, 0.3], 1)"
$PSQL "SELECT nonexistent_fn()"                               # capture ErrorResponse shape
$PSQL "DROP COLLECTION spike_t"
```
Then dump per-column OIDs with a raw describe (psql `\gdesc`):

```bash
psql "host=localhost port=16432 user=<USER> dbname=<DB>" \
  -c "SELECT id, n, f, b, ts, emb FROM spike_t \gdesc" 2>/dev/null || true
```
(Re-create the collection first if needed; `\gdesc` prints column type per OID.) Record: every OID, the exact text of the timestamp value, and the exact text serialization of the vector column (expected pg-standard `{0.1,0.2,0.3}` — if it differs, Task 12's array parser must follow what you record here).

- [ ] **Step 6: Write `docs/wire-facts.md`**

Structure:

```markdown
# NodeDB 0.4.0 wire facts (spiked 2026-07-23)
- Docker: farhansyah/nodedb:<tag or digest>
- Connect: host=localhost port=16432 user=<u> dbname=<d> auth=<trust|scram-sha-256> password=<if any>
- server_version: "<verbatim>"
- OIDs observed: id=25 n=23 f=701 b=16 ts=1114 emb=<1021|1022>
- Timestamp text: "<verbatim>"
- Vector text: "<verbatim>"
- ErrorResponse fields: S=<severity> C=<sqlstate> M=<message verbatim>
```

- [ ] **Step 7: Commit**

```bash
git add docs/wire-facts.md && git commit -m "Spike: record NodeDB 0.4.0 wire facts from live container"
```

---

### Task 2: Shard skeleton

**Files:**
- Create: `shard.yml`, `LICENSE`, `.gitignore`, `src/nodedb.cr`, `src/nodedb/errors.cr`, `spec/spec_helper.cr`, `.github/workflows/ci.yml`

**Interfaces:**
- Produces: `NodeDB::VERSION : String`; exception hierarchy `NodeDB::Error < DB::Error`, `NodeDB::ConnectionError < NodeDB::Error`, `NodeDB::QueryError < NodeDB::Error` (carries `sqlstate : String?`); `spec_helper` with `with_nodedb(&)` integration gate. All later tasks require these names exactly.

- [ ] **Step 1: Write `shard.yml`**

```yaml
name: nodedb
version: 0.1.0
description: |
  Crystal client for NodeDB — crystal-db driver (pgwire) plus SQL builders
  for vector, graph, FTS, KV, timeseries, spatial, and collection DDL.
authors:
  - emanzx <emanzx@gmail.com>
license: BSD-2-Clause
crystal: ">= 1.14.0"
dependencies:
  db:
    github: crystal-lang/crystal-db
    version: ~> 0.13
```

- [ ] **Step 2: Write `LICENSE`** — BSD-2-Clause text, `Copyright (c) 2026, emanzx`. Copy the body verbatim from https://opensource.org/license/bsd-2-clause (or nodedb-ruby's `LICENSE.md`, swapping the copyright line).

- [ ] **Step 3: Write `.gitignore`**

```
/lib/
/bin/
/.shards/
*.dwarf
```

- [ ] **Step 4: Write `src/nodedb/errors.cr`**

```crystal
require "db"

module NodeDB
  class Error < ::DB::Error
  end

  class ConnectionError < Error
  end

  class QueryError < Error
    getter sqlstate : String?

    def initialize(message : String, @sqlstate : String? = nil)
      super(message)
    end
  end
end
```

- [ ] **Step 5: Write `src/nodedb.cr`**

```crystal
require "db"
require "./nodedb/errors"

module NodeDB
  VERSION = "0.1.0"
end
```

- [ ] **Step 6: Write `spec/spec_helper.cr`**

```crystal
require "spec"
require "../src/nodedb"

# Integration gate: yields an open DB::Database only when NODEDB_URL is set,
# otherwise marks the example pending. Usable from any *_spec.cr.
def with_nodedb(&)
  url = ENV["NODEDB_URL"]?
  pending! "NODEDB_URL not set — integration spec skipped" unless url
  DB.open(url) do |db|
    yield db
  end
end
```

(Note: `DB.open` with scheme `nodedb` only works after Task 13 registers the driver; nothing calls `with_nodedb` before then.)

- [ ] **Step 7: Write `.github/workflows/ci.yml`** (unit-only for now; Task 15 adds the integration job)

```yaml
name: CI
on: [push, pull_request]
jobs:
  unit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: crystal-lang/install-crystal@v1
        with: {crystal: latest}
      - run: shards install
      - run: crystal tool format --check src spec
      - run: crystal spec
```

- [ ] **Step 8: Verify green**

```bash
shards install && crystal spec && crystal tool format --check src spec
```
Expected: `Finished` with 0 examples, 0 failures; format clean.

- [ ] **Step 9: Commit**

```bash
git add -A && git commit -m "Shard skeleton: shard.yml, errors, spec helper, CI"
```

---

### Task 3: `NodeDB::SQL::Quoting`

**Files:**
- Create: `src/nodedb/sql/quoting.cr`, `spec/sql/quoting_spec.cr`
- Modify: `src/nodedb.cr` (add `require "./nodedb/sql/quoting"`)

**Interfaces:**
- Produces (every builder + the driver's `$n` substitution consume these — exact signatures):
  - `NodeDB::SQL::Quoting.identifier(name : String) : String` — returns `name` unchanged or raises `ArgumentError`
  - `NodeDB::SQL::Quoting.string(value : String) : String` — `'...'` with `''` doubling; raises `ArgumentError` if value contains `\0`
  - `NodeDB::SQL::Quoting.literal(value) : String` — serializes `String | Int32 | Int64 | Float32 | Float64 | Bool | Time | Nil | Array(Float32) | Array(Float64)` to a SQL literal (Time → `'%F %T.%6N'` UTC string; arrays → `ARRAY[...]`; nil → `NULL`)

- [ ] **Step 1: Write the failing spec `spec/sql/quoting_spec.cr`**

```crystal
require "../spec_helper"

describe NodeDB::SQL::Quoting do
  describe ".identifier" do
    it "accepts valid identifiers unchanged" do
      NodeDB::SQL::Quoting.identifier("articles").should eq("articles")
      NodeDB::SQL::Quoting.identifier("_private2").should eq("_private2")
    end

    it "rejects invalid identifiers" do
      expect_raises(ArgumentError) { NodeDB::SQL::Quoting.identifier("bad name") }
      expect_raises(ArgumentError) { NodeDB::SQL::Quoting.identifier("1starts") }
      expect_raises(ArgumentError) { NodeDB::SQL::Quoting.identifier("a;drop") }
      expect_raises(ArgumentError) { NodeDB::SQL::Quoting.identifier("") }
      expect_raises(ArgumentError) { NodeDB::SQL::Quoting.identifier("émbe") }
    end
  end

  describe ".string" do
    it "single-quotes and doubles embedded quotes" do
      NodeDB::SQL::Quoting.string("alice").should eq("'alice'")
      NodeDB::SQL::Quoting.string("o'brien").should eq("'o''brien'")
      NodeDB::SQL::Quoting.string("it''s").should eq("'it''''s'")
    end

    it "rejects NUL bytes" do
      expect_raises(ArgumentError) { NodeDB::SQL::Quoting.string("a b") }
    end
  end

  describe ".literal" do
    it "serializes scalars" do
      NodeDB::SQL::Quoting.literal("x").should eq("'x'")
      NodeDB::SQL::Quoting.literal(42).should eq("42")
      NodeDB::SQL::Quoting.literal(1.5).should eq("1.5")
      NodeDB::SQL::Quoting.literal(true).should eq("TRUE")
      NodeDB::SQL::Quoting.literal(nil).should eq("NULL")
    end

    it "serializes Time as UTC timestamp literal" do
      t = Time.utc(2026, 7, 23, 10, 0, 0)
      NodeDB::SQL::Quoting.literal(t).should eq("'2026-07-23 10:00:00.000000'")
    end

    it "serializes float arrays as ARRAY literals" do
      NodeDB::SQL::Quoting.literal([0.1, 0.2] of Float64).should eq("ARRAY[0.1, 0.2]")
      NodeDB::SQL::Quoting.literal([0.5_f32] of Float32).should eq("ARRAY[0.5]")
    end
  end
end
```

- [ ] **Step 2: Run to verify fail** — `crystal spec spec/sql/quoting_spec.cr` → compile error `undefined constant NodeDB::SQL::Quoting`.

- [ ] **Step 3: Write `src/nodedb/sql/quoting.cr`**

```crystal
module NodeDB
  module SQL
    # The single home of identifier validation and value escaping.
    # Identifiers are validated, NOT double-quoted: NodeDB's SEARCH command
    # rejects quoted identifiers (upstream quirk documented by nodedb-ruby).
    module Quoting
      IDENTIFIER_RE = /\A[A-Za-z_][A-Za-z0-9_]*\z/

      def self.identifier(name : String) : String
        raise ArgumentError.new("invalid identifier: #{name.inspect}") unless IDENTIFIER_RE.matches?(name)
        name
      end

      def self.string(value : String) : String
        raise ArgumentError.new("string literal cannot contain NUL") if value.includes?(' ')
        "'#{value.gsub("'", "''")}'"
      end

      def self.literal(value : String) : String
        string(value)
      end

      def self.literal(value : Int | Float) : String
        value.to_s
      end

      def self.literal(value : Bool) : String
        value ? "TRUE" : "FALSE"
      end

      def self.literal(value : Nil) : String
        "NULL"
      end

      def self.literal(value : Time) : String
        "'#{value.to_utc.to_s("%F %T.%6N")}'"
      end

      def self.literal(value : Array(Float32) | Array(Float64)) : String
        "ARRAY[#{value.map(&.to_f64).join(", ")}]"
      end
    end
  end
end
```

Add to `src/nodedb.cr` after the errors require: `require "./nodedb/sql/quoting"`.

- [ ] **Step 4: Run to verify pass** — `crystal spec spec/sql/quoting_spec.cr` → all pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Add SQL::Quoting: identifier allowlist + value literals"
```

---

### Task 4: `NodeDB::SQL::Vector`

**Files:**
- Create: `src/nodedb/sql/vector.cr`, `spec/sql/vector_spec.cr`
- Modify: `src/nodedb.cr` (require)

**Interfaces:**
- Consumes: `Quoting.identifier`, `Quoting.literal(Array)`.
- Produces: `NodeDB::SQL::Vector.search(table : String, column : String, embedding : Array(Float32) | Array(Float64), limit : Int32, filter : String? = nil) : String`

Ruby reference output (must match): `SEARCH articles USING VECTOR(embedding, ARRAY[0.1, 0.2, 0.3], 10)` + optional ` WHERE <filter>`.

- [ ] **Step 1: Failing spec `spec/sql/vector_spec.cr`**

```crystal
require "../spec_helper"

describe NodeDB::SQL::Vector do
  it "builds SEARCH ... USING VECTOR" do
    sql = NodeDB::SQL::Vector.search(
      table: "articles", column: "embedding",
      embedding: [0.1, 0.2, 0.3] of Float64, limit: 10)
    sql.should eq("SEARCH articles USING VECTOR(embedding, ARRAY[0.1, 0.2, 0.3], 10)")
  end

  it "appends WHERE when filter given" do
    sql = NodeDB::SQL::Vector.search(
      table: "articles", column: "embedding",
      embedding: [1.0] of Float64, limit: 5, filter: "category = 'tech'")
    sql.should eq("SEARCH articles USING VECTOR(embedding, ARRAY[1.0], 5) WHERE category = 'tech'")
  end

  it "validates identifiers" do
    expect_raises(ArgumentError) do
      NodeDB::SQL::Vector.search(table: "bad table", column: "c",
        embedding: [1.0] of Float64, limit: 1)
    end
  end

  it "rejects empty embeddings and non-positive limits" do
    expect_raises(ArgumentError) do
      NodeDB::SQL::Vector.search(table: "t", column: "c",
        embedding: [] of Float64, limit: 1)
    end
    expect_raises(ArgumentError) do
      NodeDB::SQL::Vector.search(table: "t", column: "c",
        embedding: [1.0] of Float64, limit: 0)
    end
  end
end
```

- [ ] **Step 2: Run to verify fail** — `crystal spec spec/sql/vector_spec.cr` → undefined constant.

- [ ] **Step 3: Write `src/nodedb/sql/vector.cr`**

```crystal
module NodeDB
  module SQL
    # Builder for NodeDB vector search (SEARCH ... USING VECTOR).
    module Vector
      # filter is a raw SQL fragment appended as WHERE — caller-trusted,
      # like nodedb-ruby's filter: kwarg.
      def self.search(table : String, column : String,
                      embedding : Array(Float32) | Array(Float64),
                      limit : Int32, filter : String? = nil) : String
        raise ArgumentError.new("embedding must not be empty") if embedding.empty?
        raise ArgumentError.new("limit must be positive") unless limit.positive?
        sql = String.build do |s|
          s << "SEARCH " << Quoting.identifier(table)
          s << " USING VECTOR(" << Quoting.identifier(column)
          s << ", " << Quoting.literal(embedding) << ", " << limit << ')'
        end
        filter ? "#{sql} WHERE #{filter}" : sql
      end
    end
  end
end
```

Add `require "./nodedb/sql/vector"` to `src/nodedb.cr`.

- [ ] **Step 4: Run to verify pass**, then full `crystal spec` + format check.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "Add SQL::Vector builder"`

---

### Task 5: `NodeDB::SQL::Graph`

**Files:**
- Create: `src/nodedb/sql/graph.cr`, `spec/sql/graph_spec.cr`
- Modify: `src/nodedb.cr` (require)

**Interfaces:**
- Consumes: `Quoting.identifier`, `Quoting.string`.
- Produces:
  - `alias NodeDB::SQL::Graph::PropValue = String | Int32 | Int64 | Float64 | Bool | Nil`
  - `alias NodeDB::SQL::Graph::AlgoValue = String | Int32 | Int64 | Float64 | Bool | Array(String) | Hash(String, Float64)`
  - `Graph.insert_edge(in_collection : String, from : String, to : String, type : String, properties : Hash(String, PropValue) = {} of String => PropValue) : String`
  - `Graph.traverse(from : String, depth : Int32, direction : Direction = :both) : String` where `enum Direction; Both; Inbound; Outbound; end`
  - `Graph.algo(table : String, algo : String, options : Hash(String, AlgoValue) = {} of String => AlgoValue) : String`
  - `Graph.delete_edge(in_collection : String, from : String, to : String, type : String) : String`
  - `Graph.stats(collection : String? = nil, verbose : Bool = false, as_of : Int64? = nil) : String`

Ruby reference outputs (values arrive pre-quoted in ruby; ours quote internally — same rendered SQL):
- `GRAPH INSERT EDGE IN social_nodes FROM 'alice' TO 'bob' TYPE 'knows' PROPERTIES '{"since":2020}'`
- `GRAPH TRAVERSE FROM 'alice' DEPTH 2` (+ ` DIRECTION OUTBOUND` when not both)
- `GRAPH ALGO PAGERANK ON social_nodes ITERATIONS 20 PERSONALIZATION {"alice":1.0}`
- `GRAPH DELETE EDGE IN social_nodes FROM 'alice' TO 'bob' TYPE 'knows'`
- `SHOW GRAPH STATS social_nodes VERBOSE AS OF SYSTEM TIME 1753246800000`

- [ ] **Step 1: Failing spec `spec/sql/graph_spec.cr`**

```crystal
require "../spec_helper"

describe NodeDB::SQL::Graph do
  it "builds insert_edge with JSON properties" do
    sql = NodeDB::SQL::Graph.insert_edge(
      in_collection: "social_nodes", from: "alice", to: "bob", type: "knows",
      properties: {"since" => 2020} of String => NodeDB::SQL::Graph::PropValue)
    sql.should eq(%(GRAPH INSERT EDGE IN social_nodes FROM 'alice' TO 'bob' TYPE 'knows' PROPERTIES '{"since":2020}'))
  end

  it "builds insert_edge without properties" do
    sql = NodeDB::SQL::Graph.insert_edge(
      in_collection: "g", from: "a", to: "b", type: "t")
    sql.should eq("GRAPH INSERT EDGE IN g FROM 'a' TO 'b' TYPE 't' PROPERTIES '{}'")
  end

  it "escapes node ids" do
    sql = NodeDB::SQL::Graph.insert_edge(
      in_collection: "g", from: "o'brien", to: "b", type: "t")
    sql.should contain("FROM 'o''brien'")
  end

  it "builds traverse with and without direction" do
    NodeDB::SQL::Graph.traverse(from: "alice", depth: 2)
      .should eq("GRAPH TRAVERSE FROM 'alice' DEPTH 2")
    NodeDB::SQL::Graph.traverse(from: "alice", depth: 3, direction: :outbound)
      .should eq("GRAPH TRAVERSE FROM 'alice' DEPTH 3 DIRECTION OUTBOUND")
  end

  it "builds algo with JSON-encoded hash options" do
    sql = NodeDB::SQL::Graph.algo(table: "social_nodes", algo: "pagerank",
      options: {"iterations" => 20, "personalization" => {"alice" => 1.0}} of String => NodeDB::SQL::Graph::AlgoValue)
    sql.should eq(%(GRAPH ALGO PAGERANK ON social_nodes ITERATIONS 20 PERSONALIZATION {"alice":1.0}))
  end

  it "builds algo without options" do
    NodeDB::SQL::Graph.algo(table: "g", algo: "scc").should eq("GRAPH ALGO SCC ON g")
  end

  it "builds delete_edge" do
    NodeDB::SQL::Graph.delete_edge(in_collection: "g", from: "a", to: "b", type: "t")
      .should eq("GRAPH DELETE EDGE IN g FROM 'a' TO 'b' TYPE 't'")
  end

  it "builds stats variants" do
    NodeDB::SQL::Graph.stats.should eq("SHOW GRAPH STATS")
    NodeDB::SQL::Graph.stats(collection: "g", verbose: true, as_of: 1753246800000_i64)
      .should eq("SHOW GRAPH STATS g VERBOSE AS OF SYSTEM TIME 1753246800000")
  end
end
```

- [ ] **Step 2: Run to verify fail.**

- [ ] **Step 3: Write `src/nodedb/sql/graph.cr`**

```crystal
require "json"

module NodeDB
  module SQL
    # Builders for NodeDB graph operations (GRAPH INSERT/TRAVERSE/ALGO/DELETE,
    # SHOW GRAPH STATS). The IN <collection> clause is required by current
    # upstream syntax for edge insert/delete.
    module Graph
      alias PropValue = String | Int32 | Int64 | Float64 | Bool | Nil
      alias AlgoValue = String | Int32 | Int64 | Float64 | Bool | Array(String) | Hash(String, Float64)

      enum Direction
        Both
        Inbound
        Outbound
      end

      def self.insert_edge(in_collection : String, from : String, to : String, type : String,
                           properties : Hash(String, PropValue) = {} of String => PropValue) : String
        String.build do |s|
          s << "GRAPH INSERT EDGE IN " << Quoting.identifier(in_collection)
          s << " FROM " << Quoting.string(from) << " TO " << Quoting.string(to)
          s << " TYPE " << Quoting.string(type)
          s << " PROPERTIES " << Quoting.string(properties.to_json)
        end
      end

      def self.traverse(from : String, depth : Int32, direction : Direction = :both) : String
        sql = "GRAPH TRAVERSE FROM #{Quoting.string(from)} DEPTH #{depth}"
        direction.both? ? sql : "#{sql} DIRECTION #{direction.to_s.upcase}"
      end

      # Hash/Array option values are JSON-encoded so e.g. personalized
      # PageRank renders PERSONALIZATION {"alice":1.0} (parser-valid),
      # mirroring nodedb-ruby's render_algo_value.
      def self.algo(table : String, algo : String,
                    options : Hash(String, AlgoValue) = {} of String => AlgoValue) : String
        String.build do |s|
          s << "GRAPH ALGO " << Quoting.identifier(algo).upcase
          s << " ON " << Quoting.identifier(table)
          options.each do |key, value|
            s << ' ' << Quoting.identifier(key).upcase << ' ' << render_algo_value(value)
          end
        end
      end

      def self.delete_edge(in_collection : String, from : String, to : String, type : String) : String
        String.build do |s|
          s << "GRAPH DELETE EDGE IN " << Quoting.identifier(in_collection)
          s << " FROM " << Quoting.string(from) << " TO " << Quoting.string(to)
          s << " TYPE " << Quoting.string(type)
        end
      end

      def self.stats(collection : String? = nil, verbose : Bool = false, as_of : Int64? = nil) : String
        String.build do |s|
          s << "SHOW GRAPH STATS"
          s << ' ' << Quoting.identifier(collection) if collection
          s << " VERBOSE" if verbose
          s << " AS OF SYSTEM TIME " << as_of if as_of
        end
      end

      private def self.render_algo_value(value : Hash | Array) : String
        value.to_json
      end

      private def self.render_algo_value(value) : String
        value.to_s
      end
    end
  end
end
```

Add require to `src/nodedb.cr`.

- [ ] **Step 4: Run to verify pass**, full suite + format.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "Add SQL::Graph builders"`

---

### Task 6: `NodeDB::SQL::FTS`

**Files:**
- Create: `src/nodedb/sql/fts.cr`, `spec/sql/fts_spec.cr`
- Modify: `src/nodedb.cr` (require)

**Interfaces:**
- Consumes: `Quoting.identifier`, `Quoting.string`.
- Produces:
  - `FTS.create_index(name : String, collection : String, column : String) : String`
  - `FTS.drop_index(name : String) : String` (renders generic `DROP INDEX` — NodeDB has no `DROP FULLTEXT INDEX`)
  - `FTS.search(table : String, column : String, query : String, limit : Int32, fuzzy : Bool = false) : String`

Ruby reference outputs:
- `CREATE FULLTEXT INDEX idx ON posts (body)`
- `DROP INDEX idx`
- `SELECT id FROM posts WHERE text_match(body, 'machine learning') LIMIT 20`
- fuzzy: `text_match(body, 'term', { fuzzy: true, distance: 2 })`

- [ ] **Step 1: Failing spec `spec/sql/fts_spec.cr`**

```crystal
require "../spec_helper"

describe NodeDB::SQL::FTS do
  it "builds create_index / drop_index" do
    NodeDB::SQL::FTS.create_index(name: "idx", collection: "posts", column: "body")
      .should eq("CREATE FULLTEXT INDEX idx ON posts (body)")
    NodeDB::SQL::FTS.drop_index("idx").should eq("DROP INDEX idx")
  end

  it "builds search with escaped query value" do
    NodeDB::SQL::FTS.search(table: "posts", column: "body", query: "machine learning", limit: 20)
      .should eq("SELECT id FROM posts WHERE text_match(body, 'machine learning') LIMIT 20")
    NodeDB::SQL::FTS.search(table: "posts", column: "body", query: "o'brien", limit: 1)
      .should contain("text_match(body, 'o''brien')")
  end

  it "adds fuzzy options" do
    NodeDB::SQL::FTS.search(table: "posts", column: "body", query: "t", limit: 5, fuzzy: true)
      .should eq("SELECT id FROM posts WHERE text_match(body, 't', { fuzzy: true, distance: 2 }) LIMIT 5")
  end

  it "rejects non-positive limit" do
    expect_raises(ArgumentError) do
      NodeDB::SQL::FTS.search(table: "p", column: "b", query: "q", limit: 0)
    end
  end
end
```

- [ ] **Step 2: Run to verify fail.**

- [ ] **Step 3: Write `src/nodedb/sql/fts.cr`**

```crystal
module NodeDB
  module SQL
    # Full-text search builders. FTS runs on a document collection with a
    # separate CREATE FULLTEXT INDEX; text_match() filters server-side.
    module FTS
      def self.create_index(name : String, collection : String, column : String) : String
        "CREATE FULLTEXT INDEX #{Quoting.identifier(name)} ON #{Quoting.identifier(collection)} (#{Quoting.identifier(column)})"
      end

      def self.drop_index(name : String) : String
        "DROP INDEX #{Quoting.identifier(name)}"
      end

      def self.search(table : String, column : String, query : String,
                      limit : Int32, fuzzy : Bool = false) : String
        raise ArgumentError.new("limit must be positive") unless limit.positive?
        fuzzy_opts = fuzzy ? ", { fuzzy: true, distance: 2 }" : ""
        "SELECT id FROM #{Quoting.identifier(table)} " \
        "WHERE text_match(#{Quoting.identifier(column)}, #{Quoting.string(query)}#{fuzzy_opts}) " \
        "LIMIT #{limit}"
      end
    end
  end
end
```

Add require to `src/nodedb.cr`.

- [ ] **Step 4: Run to verify pass**, full suite + format.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "Add SQL::FTS builders"`

---

### Task 7: `NodeDB::SQL::KV`, `Timeseries`, `Spatial`

**Files:**
- Create: `src/nodedb/sql/kv.cr`, `src/nodedb/sql/timeseries.cr`, `src/nodedb/sql/spatial.cr`, `spec/sql/kv_spec.cr`, `spec/sql/timeseries_spec.cr`, `spec/sql/spatial_spec.cr`
- Modify: `src/nodedb.cr` (requires)

**Interfaces:**
- Produces:
  - `KV.set_ttl(table : String, key : String, ttl : Int32) : String` (nodedb-ruby's KV has ONLY set_ttl — the README's set/get don't exist in its lib; do not invent them)
  - `Timeseries.time_bucket(interval : String, as_alias : String = "bucket") : String`
  - `Timeseries.epoch_ms(time : Time) : Int64`
  - `Timeseries.since_clause(time : Time) : String` / `until_clause(time : Time) : String`
  - `Spatial.within_distance(column : String, lat : Float64, lon : Float64, meters : Float64) : String`
  - `Spatial.distance_expr(column : String, lat : Float64, lon : Float64, as_alias : String = "distance") : String`
  - `Spatial.bbox_filter(column : String, min_lon : Float64, min_lat : Float64, max_lon : Float64, max_lat : Float64) : String`

Ruby reference outputs:
- `UPDATE sessions SET ttl = 3600 WHERE key = 'user:1'`
- `time_bucket('1h', timestamp) AS bucket` · `timestamp > 1753246800000` · `timestamp <= 1753246800000`
- `ST_DWithin(geom, ST_Point(101.7, 3.15), 500.0)` — note **lon first** in ST_Point
- `ST_Distance(geom, ST_Point(101.7, 3.15)) AS distance`
- `geom && ST_MakeEnvelope(101.0, 3.0, 102.0, 4.0, 4326)`

Divergence notes: `as:` is a Crystal keyword → `as_alias`; `epoch_ms` uses `to_unix_ms` (ruby truncates to whole seconds — ours keeps ms precision; SQL shape identical). Interval strings are validated against `/\A\d+(us|ms|s|m|h|d|w)\z/`.

- [ ] **Step 1: Failing specs (all three files)**

`spec/sql/kv_spec.cr`:

```crystal
require "../spec_helper"

describe NodeDB::SQL::KV do
  it "builds set_ttl" do
    NodeDB::SQL::KV.set_ttl(table: "sessions", key: "user:1", ttl: 3600)
      .should eq("UPDATE sessions SET ttl = 3600 WHERE key = 'user:1'")
  end

  it "escapes key and validates table" do
    NodeDB::SQL::KV.set_ttl(table: "s", key: "o'brien", ttl: 1)
      .should contain("key = 'o''brien'")
    expect_raises(ArgumentError) { NodeDB::SQL::KV.set_ttl(table: "bad name", key: "k", ttl: 1) }
  end
end
```

`spec/sql/timeseries_spec.cr`:

```crystal
require "../spec_helper"

describe NodeDB::SQL::Timeseries do
  it "builds time_bucket" do
    NodeDB::SQL::Timeseries.time_bucket("1h").should eq("time_bucket('1h', timestamp) AS bucket")
    NodeDB::SQL::Timeseries.time_bucket("5m", as_alias: "b5").should eq("time_bucket('5m', timestamp) AS b5")
  end

  it "rejects malformed intervals" do
    expect_raises(ArgumentError) { NodeDB::SQL::Timeseries.time_bucket("1h; DROP") }
  end

  it "converts times to epoch ms and builds clauses" do
    t = Time.utc(2026, 7, 23, 5, 0, 0)
    NodeDB::SQL::Timeseries.epoch_ms(t).should eq(1784178000000_i64)
    NodeDB::SQL::Timeseries.since_clause(t).should eq("timestamp > 1784178000000")
    NodeDB::SQL::Timeseries.until_clause(t).should eq("timestamp <= 1784178000000")
  end
end
```

`spec/sql/spatial_spec.cr`:

```crystal
require "../spec_helper"

describe NodeDB::SQL::Spatial do
  it "builds within_distance with lon-first ST_Point" do
    NodeDB::SQL::Spatial.within_distance(column: "geom", lat: 3.15, lon: 101.7, meters: 500.0)
      .should eq("ST_DWithin(geom, ST_Point(101.7, 3.15), 500.0)")
  end

  it "builds distance_expr" do
    NodeDB::SQL::Spatial.distance_expr(column: "geom", lat: 3.15, lon: 101.7)
      .should eq("ST_Distance(geom, ST_Point(101.7, 3.15)) AS distance")
  end

  it "builds bbox_filter" do
    NodeDB::SQL::Spatial.bbox_filter(column: "geom", min_lon: 101.0, min_lat: 3.0, max_lon: 102.0, max_lat: 4.0)
      .should eq("geom && ST_MakeEnvelope(101.0, 3.0, 102.0, 4.0, 4326)")
  end
end
```

- [ ] **Step 2: Run to verify fail.**

- [ ] **Step 3: Write the three modules**

`src/nodedb/sql/kv.cr`:

```crystal
module NodeDB
  module SQL
    # KV engine helpers. Deliberately only set_ttl — matches nodedb-ruby's lib.
    module KV
      def self.set_ttl(table : String, key : String, ttl : Int32) : String
        "UPDATE #{Quoting.identifier(table)} SET ttl = #{ttl} WHERE key = #{Quoting.string(key)}"
      end
    end
  end
end
```

`src/nodedb/sql/timeseries.cr`:

```crystal
module NodeDB
  module SQL
    # Timeseries helpers. NodeDB renames the TIME_KEY column to `timestamp`
    # internally and filters on epoch-ms integers.
    module Timeseries
      INTERVAL_RE = /\A\d+(us|ms|s|m|h|d|w)\z/

      def self.time_bucket(interval : String, as_alias : String = "bucket") : String
        raise ArgumentError.new("invalid interval: #{interval.inspect}") unless INTERVAL_RE.matches?(interval)
        "time_bucket('#{interval}', timestamp) AS #{Quoting.identifier(as_alias)}"
      end

      def self.epoch_ms(time : Time) : Int64
        time.to_unix_ms
      end

      def self.since_clause(time : Time) : String
        "timestamp > #{epoch_ms(time)}"
      end

      def self.until_clause(time : Time) : String
        "timestamp <= #{epoch_ms(time)}"
      end
    end
  end
end
```

`src/nodedb/sql/spatial.cr`:

```crystal
module NodeDB
  module SQL
    # Spatial expression builders (ST_* functions). ST_Point takes lon, lat.
    module Spatial
      def self.within_distance(column : String, lat : Float64, lon : Float64, meters : Float64) : String
        "ST_DWithin(#{Quoting.identifier(column)}, ST_Point(#{lon}, #{lat}), #{meters})"
      end

      def self.distance_expr(column : String, lat : Float64, lon : Float64,
                             as_alias : String = "distance") : String
        "ST_Distance(#{Quoting.identifier(column)}, ST_Point(#{lon}, #{lat})) AS #{Quoting.identifier(as_alias)}"
      end

      def self.bbox_filter(column : String, min_lon : Float64, min_lat : Float64,
                           max_lon : Float64, max_lat : Float64) : String
        "#{Quoting.identifier(column)} && ST_MakeEnvelope(#{min_lon}, #{min_lat}, #{max_lon}, #{max_lat}, 4326)"
      end
    end
  end
end
```

Add the three requires to `src/nodedb.cr`.

- [ ] **Step 4: Run to verify pass**, full suite + format.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "Add SQL::KV, SQL::Timeseries, SQL::Spatial builders"`

---

### Task 8: `NodeDB::SQL::Collection`

**Files:**
- Create: `src/nodedb/sql/collection.cr`, `spec/sql/collection_spec.cr`
- Modify: `src/nodedb.cr` (require)

**Interfaces:**
- Produces:
  - `Collection.create(name : String, engine : String? = nil, columns : Array(String) = [] of String, engine_options : Hash(String, String) = {} of String => String, flags : Array(String) = [] of String) : String`
  - `Collection.drop(name : String) : String` / `drop_if_exists(name : String) : String`
  - `Collection.show : String` / `describe(name : String) : String`

Ruby reference behavior (port exactly):
- default columns when `columns` empty: timeseries → `["ts TIMESTAMP TIME_KEY", "value FLOAT"]`, kv → `["key TEXT PRIMARY KEY", "value TEXT"]`
- flags upcased into the column parens: `CREATE COLLECTION orders (id TEXT PRIMARY KEY, BITEMPORAL) WITH (engine='document_strict')`
- `engine: "fts"` maps to `document_strict`; `"document"`/nil → no engine pair
- engine_options: keys validated `/\A[A-Za-z_][A-Za-z0-9_]*\z/`, values `'`-escaped: `WITH (engine='timeseries', retention='7d')`
- no parens at all when columns+flags empty; no WITH when engine nil and options empty

- [ ] **Step 1: Failing spec `spec/sql/collection_spec.cr`**

```crystal
require "../spec_helper"

describe NodeDB::SQL::Collection do
  it "builds bare document collection" do
    NodeDB::SQL::Collection.create("notes").should eq("CREATE COLLECTION notes")
  end

  it "builds timeseries with default columns and options" do
    sql = NodeDB::SQL::Collection.create("metrics", engine: "timeseries",
      engine_options: {"retention" => "7d"})
    sql.should eq("CREATE COLLECTION metrics (ts TIMESTAMP TIME_KEY, value FLOAT) WITH (engine='timeseries', retention='7d')")
  end

  it "builds kv default columns" do
    NodeDB::SQL::Collection.create("cache", engine: "kv")
      .should eq("CREATE COLLECTION cache (key TEXT PRIMARY KEY, value TEXT) WITH (engine='kv')")
  end

  it "appends upcased flags inside parens" do
    sql = NodeDB::SQL::Collection.create("orders", engine: "document_strict",
      columns: ["id TEXT PRIMARY KEY", "total NUMERIC"], flags: ["bitemporal"])
    sql.should eq("CREATE COLLECTION orders (id TEXT PRIMARY KEY, total NUMERIC, BITEMPORAL) WITH (engine='document_strict')")
  end

  it "maps fts engine to document_strict and document to none" do
    NodeDB::SQL::Collection.create("posts", engine: "fts")
      .should eq("CREATE COLLECTION posts WITH (engine='document_strict')")
    NodeDB::SQL::Collection.create("posts", engine: "document")
      .should eq("CREATE COLLECTION posts")
  end

  it "escapes option values and validates option keys" do
    NodeDB::SQL::Collection.create("t", engine_options: {"note" => "it's"})
      .should eq("CREATE COLLECTION t WITH (note='it''s')")
    expect_raises(ArgumentError) do
      NodeDB::SQL::Collection.create("t", engine_options: {"bad key" => "v"})
    end
  end

  it "builds drop/show/describe" do
    NodeDB::SQL::Collection.drop("t").should eq("DROP COLLECTION t")
    NodeDB::SQL::Collection.drop_if_exists("t").should eq("DROP COLLECTION IF EXISTS t")
    NodeDB::SQL::Collection.show.should eq("SHOW COLLECTIONS")
    NodeDB::SQL::Collection.describe("t").should eq("DESCRIBE t")
  end
end
```

- [ ] **Step 2: Run to verify fail.**

- [ ] **Step 3: Write `src/nodedb/sql/collection.cr`**

```crystal
module NodeDB
  module SQL
    # Collection DDL builders. `columns` entries are raw "name TYPE [constraints]"
    # fragments (caller-trusted, like nodedb-ruby). Engine "fts" maps to
    # document_strict — the standalone fts engine was removed upstream.
    module Collection
      DEFAULT_COLUMNS = {
        "timeseries" => ["ts TIMESTAMP TIME_KEY", "value FLOAT"],
        "kv"         => ["key TEXT PRIMARY KEY", "value TEXT"],
      }

      def self.create(name : String, engine : String? = nil,
                      columns : Array(String) = [] of String,
                      engine_options : Hash(String, String) = {} of String => String,
                      flags : Array(String) = [] of String) : String
        col_parts = columns.empty? ? (DEFAULT_COLUMNS[engine]? || [] of String) : columns
        body_parts = col_parts + flags.map(&.upcase)

        sql = "CREATE COLLECTION #{Quoting.identifier(name)}"
        sql += " (#{body_parts.join(", ")})" unless body_parts.empty?
        with_clause = build_with_clause(engine, engine_options)
        with_clause ? "#{sql} #{with_clause}" : sql
      end

      def self.drop(name : String) : String
        "DROP COLLECTION #{Quoting.identifier(name)}"
      end

      def self.drop_if_exists(name : String) : String
        "DROP COLLECTION IF EXISTS #{Quoting.identifier(name)}"
      end

      def self.show : String
        "SHOW COLLECTIONS"
      end

      def self.describe(name : String) : String
        "DESCRIBE #{Quoting.identifier(name)}"
      end

      private def self.build_with_clause(engine : String?, opts : Hash(String, String)) : String?
        effective = effective_engine(engine)
        return nil if effective.nil? && opts.empty?

        pairs = [] of String
        pairs << "engine='#{effective}'" if effective
        opts.each do |key, value|
          Quoting.identifier(key)
          pairs << "#{key}='#{value.gsub("'", "''")}'"
        end
        "WITH (#{pairs.join(", ")})"
      end

      private def self.effective_engine(engine : String?) : String?
        return nil if engine.nil? || engine == "document"
        engine == "fts" ? "document_strict" : engine
      end
    end
  end
end
```

Add require to `src/nodedb.cr`.

- [ ] **Step 4: Run to verify pass**, full suite + format.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "Add SQL::Collection DDL builders"`

---

### Task 9: `NodeDB::Wire` frames

**Files:**
- Create: `src/nodedb/wire/frame.cr`, `spec/wire/frame_spec.cr`
- Modify: `src/nodedb.cr` (require `./nodedb/wire/frame`)

**Interfaces:**
- Produces (Task 11's connection consumes all of these):
  - `NodeDB::Wire::Frame.write_startup(io : IO, user : String, database : String) : Nil`
  - `Frame.write_query(io : IO, sql : String) : Nil` · `Frame.write_terminate(io : IO) : Nil`
  - `Frame.write_sasl_initial(io : IO, mechanism : String, payload : String) : Nil` · `Frame.write_sasl_response(io : IO, payload : String) : Nil`
  - `Frame.read(io : IO) : {Char, Bytes}` — one backend message: type byte + body
  - `record NodeDB::Wire::Field, name : String, oid : Int32, format : Int16`
  - `Frame.parse_row_description(body : Bytes) : Array(Field)`
  - `Frame.parse_data_row(body : Bytes) : Array(Bytes?)`
  - `Frame.parse_error(body : Bytes) : {severity: String, code: String, message: String}`
  - `Frame.parse_auth_code(body : Bytes) : Int32` and `Frame.auth_payload(body : Bytes) : Bytes` (bytes after the code)

pgwire facts this encodes (PostgreSQL Frontend/Backend Protocol v3):
- Startup (untyped): `Int32 length` + `Int32 196608` + `key\0value\0`... + `\0`; send pairs `user`, `database`, `client_encoding=UTF8`.
- Typed frontend frames: 1 type byte + `Int32 length` (length includes itself, excludes type byte). `Q` body = `sql\0`. `X` body empty. `p` = SASL messages.
- SASLInitialResponse body: `mechanism\0` + `Int32 payload_len` + payload. SASLResponse body: raw payload.
- Backend: `R` Authentication (body starts `Int32 code`: 0=OK, 10=SASL mechanisms, 11=SASL continue, 12=SASL final), `S` ParameterStatus, `K` BackendKeyData, `Z` ReadyForQuery, `T` RowDescription, `D` DataRow, `C` CommandComplete, `E` ErrorResponse, `N` NoticeResponse, `I` EmptyQueryResponse.
- `T` body: `Int16 nfields`, then per field `name\0, Int32 table_oid, Int16 attnum, Int32 type_oid, Int16 typlen, Int32 typmod, Int16 format`.
- `D` body: `Int16 ncols`, per col `Int32 len` (-1 = NULL) + bytes.
- `E` body: repeated `(Byte1 code, cstring value)` until `\0`; keep `S`, `C`, `M`.
- All integers big-endian (`IO::ByteFormat::BigEndian`).

- [ ] **Step 1: Failing spec `spec/wire/frame_spec.cr`**

```crystal
require "../spec_helper"

private def be_bytes(&)
  io = IO::Memory.new
  yield io
  io.to_slice
end

describe NodeDB::Wire::Frame do
  it "writes a startup message" do
    io = IO::Memory.new
    NodeDB::Wire::Frame.write_startup(io, user: "u", database: "d")
    bytes = io.to_slice
    # length = 4 + 4 + "user\0u\0database\0d\0client_encoding\0UTF8\0" + terminator
    len = IO::ByteFormat::BigEndian.decode(Int32, bytes[0, 4])
    len.should eq(bytes.size)
    IO::ByteFormat::BigEndian.decode(Int32, bytes[4, 4]).should eq(196608)
    String.new(bytes[8..]).should eq("user\0u\0database\0d\0client_encoding\0UTF8\0\0")
  end

  it "writes a query frame" do
    io = IO::Memory.new
    NodeDB::Wire::Frame.write_query(io, "SELECT 1")
    bytes = io.to_slice
    bytes[0].should eq('Q'.ord)
    IO::ByteFormat::BigEndian.decode(Int32, bytes[1, 4]).should eq(4 + "SELECT 1".bytesize + 1)
    String.new(bytes[5..]).should eq("SELECT 1\0")
  end

  it "reads a typed frame" do
    raw = be_bytes do |io|
      io.write_byte 'Z'.ord.to_u8
      io.write_bytes(5_i32, IO::ByteFormat::BigEndian)
      io.write_byte 'I'.ord.to_u8
    end
    type, body = NodeDB::Wire::Frame.read(IO::Memory.new(raw))
    type.should eq('Z')
    body.should eq(Bytes['I'.ord.to_u8])
  end

  it "parses RowDescription" do
    body = be_bytes do |io|
      io.write_bytes(1_i16, IO::ByteFormat::BigEndian)
      io << "id" << '\0'
      io.write_bytes(0_i32, IO::ByteFormat::BigEndian)  # table oid
      io.write_bytes(0_i16, IO::ByteFormat::BigEndian)  # attnum
      io.write_bytes(23_i32, IO::ByteFormat::BigEndian) # type oid
      io.write_bytes(4_i16, IO::ByteFormat::BigEndian)  # typlen
      io.write_bytes(-1_i32, IO::ByteFormat::BigEndian) # typmod
      io.write_bytes(0_i16, IO::ByteFormat::BigEndian)  # format = text
    end
    fields = NodeDB::Wire::Frame.parse_row_description(body)
    fields.size.should eq(1)
    fields[0].name.should eq("id")
    fields[0].oid.should eq(23)
    fields[0].format.should eq(0)
  end

  it "parses DataRow with NULL" do
    body = be_bytes do |io|
      io.write_bytes(2_i16, IO::ByteFormat::BigEndian)
      io.write_bytes(2_i32, IO::ByteFormat::BigEndian)
      io << "42"
      io.write_bytes(-1_i32, IO::ByteFormat::BigEndian)
    end
    cols = NodeDB::Wire::Frame.parse_data_row(body)
    cols.size.should eq(2)
    String.new(cols[0].not_nil!).should eq("42")
    cols[1].should be_nil
  end

  it "parses ErrorResponse fields" do
    body = be_bytes do |io|
      io << "SERROR" << '\0' << "C42601" << '\0' << "Msyntax error" << '\0' << '\0'
    end
    err = NodeDB::Wire::Frame.parse_error(body)
    err[:severity].should eq("ERROR")
    err[:code].should eq("42601")
    err[:message].should eq("syntax error")
  end

  it "parses auth code and payload" do
    body = be_bytes do |io|
      io.write_bytes(11_i32, IO::ByteFormat::BigEndian)
      io << "r=abc"
    end
    NodeDB::Wire::Frame.parse_auth_code(body).should eq(11)
    String.new(NodeDB::Wire::Frame.auth_payload(body)).should eq("r=abc")
  end
end
```

- [ ] **Step 2: Run to verify fail.**

- [ ] **Step 3: Write `src/nodedb/wire/frame.cr`**

```crystal
module NodeDB
  module Wire
    record Field, name : String, oid : Int32, format : Int16

    # pgwire v3 frame encode/decode. All integers big-endian.
    module Frame
      PROTOCOL_VERSION = 196608 # 3.0

      def self.write_startup(io : IO, user : String, database : String) : Nil
        body = IO::Memory.new
        body.write_bytes(PROTOCOL_VERSION, IO::ByteFormat::BigEndian)
        {"user" => user, "database" => database, "client_encoding" => "UTF8"}.each do |k, v|
          body << k << '\0' << v << '\0'
        end
        body.write_byte 0_u8
        io.write_bytes(body.size.to_i32 + 4, IO::ByteFormat::BigEndian)
        io.write(body.to_slice)
        io.flush
      end

      def self.write_query(io : IO, sql : String) : Nil
        write_typed(io, 'Q') { |b| b << sql << '\0' }
      end

      def self.write_terminate(io : IO) : Nil
        write_typed(io, 'X') { }
      end

      def self.write_sasl_initial(io : IO, mechanism : String, payload : String) : Nil
        write_typed(io, 'p') do |b|
          b << mechanism << '\0'
          b.write_bytes(payload.bytesize.to_i32, IO::ByteFormat::BigEndian)
          b << payload
        end
      end

      def self.write_sasl_response(io : IO, payload : String) : Nil
        write_typed(io, 'p') { |b| b << payload }
      end

      def self.read(io : IO) : {Char, Bytes}
        type = io.read_byte || raise ConnectionError.new("server closed connection")
        length = io.read_bytes(Int32, IO::ByteFormat::BigEndian)
        body = Bytes.new(length - 4)
        io.read_fully(body)
        {type.chr, body}
      end

      def self.parse_row_description(body : Bytes) : Array(Field)
        io = IO::Memory.new(body)
        Array(Field).new(io.read_bytes(Int16, IO::ByteFormat::BigEndian).to_i) do
          name = read_cstring(io)
          io.read_bytes(Int32, IO::ByteFormat::BigEndian) # table oid
          io.read_bytes(Int16, IO::ByteFormat::BigEndian) # attnum
          oid = io.read_bytes(Int32, IO::ByteFormat::BigEndian)
          io.read_bytes(Int16, IO::ByteFormat::BigEndian) # typlen
          io.read_bytes(Int32, IO::ByteFormat::BigEndian) # typmod
          format = io.read_bytes(Int16, IO::ByteFormat::BigEndian)
          Field.new(name, oid, format)
        end
      end

      def self.parse_data_row(body : Bytes) : Array(Bytes?)
        io = IO::Memory.new(body)
        Array(Bytes?).new(io.read_bytes(Int16, IO::ByteFormat::BigEndian).to_i) do
          len = io.read_bytes(Int32, IO::ByteFormat::BigEndian)
          if len < 0
            nil
          else
            value = Bytes.new(len)
            io.read_fully(value)
            value
          end
        end
      end

      def self.parse_error(body : Bytes) : {severity: String, code: String, message: String}
        severity = code = message = ""
        io = IO::Memory.new(body)
        while (field_type = io.read_byte) && field_type != 0
          value = read_cstring(io)
          case field_type.chr
          when 'S' then severity = value
          when 'C' then code = value
          when 'M' then message = value
          end
        end
        {severity: severity, code: code, message: message}
      end

      def self.parse_auth_code(body : Bytes) : Int32
        IO::ByteFormat::BigEndian.decode(Int32, body[0, 4])
      end

      def self.auth_payload(body : Bytes) : Bytes
        body[4..]
      end

      private def self.write_typed(io : IO, type : Char, & : IO::Memory ->) : Nil
        body = IO::Memory.new
        yield body
        io.write_byte type.ord.to_u8
        io.write_bytes(body.size.to_i32 + 4, IO::ByteFormat::BigEndian)
        io.write(body.to_slice)
        io.flush
      end

      private def self.read_cstring(io : IO) : String
        String.build do |s|
          while (byte = io.read_byte) && byte != 0
            s.write_byte byte
          end
        end
      end
    end
  end
end
```

Add `require "./nodedb/wire/frame"` to `src/nodedb.cr`.

- [ ] **Step 4: Run to verify pass**, full suite + format.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "Add Wire::Frame: pgwire v3 encode/decode"`

---

### Task 10: SCRAM-SHA-256

**Files:**
- Create: `src/nodedb/wire/scram.cr`, `spec/wire/scram_spec.cr`
- Modify: `src/nodedb.cr` (require)

**Interfaces:**
- Produces (Task 11 consumes):
  - `NodeDB::Wire::Scram.new(user : String, password : String, nonce : String = Random::Secure.urlsafe_base64(18))`
  - `#client_first : String` — `"n,,n=,r=<nonce>"` (username empty; server uses startup user)
  - `#client_final(server_first : String) : String` — parses `r=`,`s=`,`i=`, raises `NodeDB::ConnectionError` if server nonce doesn't extend ours, returns `"c=biws,r=<full>,p=<proof>"`
  - `#verify_server_final(server_final : String) : Nil` — raises `NodeDB::ConnectionError` on `v=` mismatch or `e=`

Algorithm (RFC 5802/7677): `SaltedPassword = PBKDF2-HMAC-SHA256(password, salt, i, 32)`; `ClientKey = HMAC(SaltedPassword, "Client Key")`; `StoredKey = SHA256(ClientKey)`; `AuthMessage = client-first-bare + "," + server-first + "," + client-final-without-proof`; `ClientProof = ClientKey XOR HMAC(StoredKey, AuthMessage)`; `ServerSignature = HMAC(HMAC(SaltedPassword, "Server Key"), AuthMessage)`.

- [ ] **Step 1: Failing spec `spec/wire/scram_spec.cr`** — uses the RFC 7677 test vector so correctness is externally anchored:

```crystal
require "../spec_helper"

# RFC 7677 §3 test vector (SCRAM-SHA-256, password "pencil").
RFC_CLIENT_NONCE = "rOprNGfwEbeRWgbNEkqO"
RFC_SERVER_FIRST = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
RFC_CLIENT_FINAL = "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="
RFC_SERVER_FINAL = "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="

describe NodeDB::Wire::Scram do
  it "produces client-first with our nonce" do
    scram = NodeDB::Wire::Scram.new(user: "user", password: "pencil", nonce: RFC_CLIENT_NONCE)
    scram.client_first.should eq("n,,n=,r=#{RFC_CLIENT_NONCE}")
  end

  it "computes the RFC 7677 client proof" do
    scram = NodeDB::Wire::Scram.new(user: "user", password: "pencil", nonce: RFC_CLIENT_NONCE)
    scram.client_first
    scram.client_final(RFC_SERVER_FIRST).should eq(RFC_CLIENT_FINAL)
  end

  it "verifies the RFC 7677 server signature" do
    scram = NodeDB::Wire::Scram.new(user: "user", password: "pencil", nonce: RFC_CLIENT_NONCE)
    scram.client_first
    scram.client_final(RFC_SERVER_FIRST)
    scram.verify_server_final(RFC_SERVER_FINAL) # must not raise
  end

  it "rejects a server nonce that does not extend ours" do
    scram = NodeDB::Wire::Scram.new(user: "u", password: "p", nonce: "abc")
    scram.client_first
    expect_raises(NodeDB::ConnectionError) do
      scram.client_final("r=EVIL,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
    end
  end

  it "rejects a bad server signature and error responses" do
    scram = NodeDB::Wire::Scram.new(user: "user", password: "pencil", nonce: RFC_CLIENT_NONCE)
    scram.client_first
    scram.client_final(RFC_SERVER_FIRST)
    expect_raises(NodeDB::ConnectionError) { scram.verify_server_final("v=AAAA") }
    expect_raises(NodeDB::ConnectionError) { scram.verify_server_final("e=other-error") }
  end
end
```

- [ ] **Step 2: Run to verify fail.**

- [ ] **Step 3: Write `src/nodedb/wire/scram.cr`**

```crystal
require "openssl"
require "openssl/pkcs5"
require "digest/sha256"
require "base64"
require "random/secure"

module NodeDB
  module Wire
    # SCRAM-SHA-256 client (RFC 5802/7677) for pgwire SASL auth.
    # Username is sent empty in client-first — the server takes the user
    # from the startup message (PostgreSQL convention).
    class Scram
      GS2_HEADER = "n,,"

      @server_signature : String?

      def initialize(@user : String, @password : String,
                     @nonce : String = Random::Secure.urlsafe_base64(18))
      end

      def client_first : String
        "#{GS2_HEADER}#{client_first_bare}"
      end

      def client_final(server_first : String) : String
        attrs = parse_attrs(server_first)
        full_nonce = attrs["r"]? || raise ConnectionError.new("SCRAM: server-first missing nonce")
        salt = attrs["s"]? || raise ConnectionError.new("SCRAM: server-first missing salt")
        iterations = (attrs["i"]? || raise ConnectionError.new("SCRAM: server-first missing iterations")).to_i
        unless full_nonce.starts_with?(@nonce) && full_nonce.size > @nonce.size
          raise ConnectionError.new("SCRAM: server nonce does not extend client nonce")
        end

        salted = OpenSSL::PKCS5.pbkdf2_hmac(@password, Base64.decode(salt),
          iterations: iterations, algorithm: OpenSSL::Algorithm::SHA256, key_size: 32)
        client_key = hmac(salted, "Client Key")
        stored_key = Digest::SHA256.digest(client_key)

        without_proof = "c=#{Base64.strict_encode(GS2_HEADER)},r=#{full_nonce}"
        auth_message = "#{client_first_bare},#{server_first},#{without_proof}"
        client_signature = hmac(stored_key, auth_message)
        proof = Bytes.new(32) { |i| client_key[i] ^ client_signature[i] }

        server_key = hmac(salted, "Server Key")
        @server_signature = Base64.strict_encode(hmac(server_key, auth_message))

        "#{without_proof},p=#{Base64.strict_encode(proof)}"
      end

      def verify_server_final(server_final : String) : Nil
        attrs = parse_attrs(server_final)
        if error = attrs["e"]?
          raise ConnectionError.new("SCRAM: server error: #{error}")
        end
        expected = @server_signature || raise ConnectionError.new("SCRAM: client_final not yet computed")
        unless attrs["v"]? == expected
          raise ConnectionError.new("SCRAM: server signature mismatch")
        end
      end

      private def client_first_bare : String
        "n=,r=#{@nonce}"
      end

      private def hmac(key, data) : Bytes
        OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, key, data)
      end

      # "r=abc,s=xyz,i=4096" → {"r" => "abc", ...}; values may contain '='
      # (base64), so split on the first '=' only.
      private def parse_attrs(message : String) : Hash(String, String)
        message.split(',').each_with_object({} of String => String) do |part, acc|
          key, _, value = part.partition('=')
          acc[key] = value unless key.empty?
        end
      end
    end
  end
end
```

Add require to `src/nodedb.cr`.

- [ ] **Step 4: Run to verify pass** (the RFC vector leaves no room for a wrong implementation), full suite + format.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "Add SCRAM-SHA-256 client with RFC 7677 vector specs"`

---

### Task 11: `NodeDB::Wire::Connection` + stub server specs

**Files:**
- Create: `src/nodedb/wire/connection.cr`, `spec/support/stub_server.cr`, `spec/wire/connection_spec.cr`
- Modify: `src/nodedb.cr` (require)

**Interfaces:**
- Consumes: `Frame.*`, `Scram`, `Field`.
- Produces (Tasks 13–14 consume):
  - `record NodeDB::Wire::Result, fields : Array(Field), rows : Array(Array(Bytes?)), command_tag : String`
  - `NodeDB::Wire::Connection.new(host : String, port : Int32, user : String, database : String, password : String? = nil)` — connects, authenticates (trust or SCRAM), waits for ReadyForQuery, then checks `SHOW server_version` and `STDERR.puts` a warning when the reported version parses below 0.4.0
  - `#query(sql : String) : Result` — sends `Q`, collects `T`/`D` frames until `Z`; `E` raises `NodeDB::QueryError` (with sqlstate) after draining to `Z`; `I` yields empty Result; multiple statements per query string are unsupported (first result wins, documented)
  - `#close : Nil` — Terminate + socket close, idempotent

- [ ] **Step 1: Write `spec/support/stub_server.cr`** (infrastructure, no spec yet)

```crystal
require "socket"
require "../../src/nodedb"

# Minimal in-process pgwire server for unit-testing Wire::Connection
# without a real NodeDB. Speaks trust auth; serves canned results.
class StubServer
  alias Row = Array(String?)
  getter port : Int32

  # queries: sql => {fields, rows} served on match; anything else → ErrorResponse
  def initialize(@queries : Hash(String, {Array(NodeDB::Wire::Field), Array(Row)}))
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    spawn { accept_loop }
  end

  def close
    @server.close
  end

  private def accept_loop
    while client = @server.accept?
      spawn handle(client)
    end
  rescue IO::Error
  end

  private def handle(io : TCPSocket)
    # Startup: length + payload (ignore contents, answer trust-ok)
    len = io.read_bytes(Int32, IO::ByteFormat::BigEndian)
    io.skip(len - 4)
    send(io, 'R') { |b| b.write_bytes(0_i32, IO::ByteFormat::BigEndian) }
    send(io, 'S') { |b| b << "server_version" << '\0' << "NodeDB 0.4.0" << '\0' }
    send(io, 'Z') { |b| b << 'I' }

    loop do
      type, body = NodeDB::Wire::Frame.read(io)
      case type
      when 'Q' then serve_query(io, String.new(body[0, body.size - 1]))
      when 'X' then break
      end
    end
  rescue IO::Error
  ensure
    io.close rescue nil
  end

  private def serve_query(io, sql)
    if canned = @queries[sql]?
      fields, rows = canned
      send(io, 'T') do |b|
        b.write_bytes(fields.size.to_i16, IO::ByteFormat::BigEndian)
        fields.each do |f|
          b << f.name << '\0'
          b.write_bytes(0_i32, IO::ByteFormat::BigEndian)
          b.write_bytes(0_i16, IO::ByteFormat::BigEndian)
          b.write_bytes(f.oid, IO::ByteFormat::BigEndian)
          b.write_bytes(0_i16, IO::ByteFormat::BigEndian)
          b.write_bytes(-1_i32, IO::ByteFormat::BigEndian)
          b.write_bytes(f.format, IO::ByteFormat::BigEndian)
        end
      end
      rows.each do |row|
        send(io, 'D') do |b|
          b.write_bytes(row.size.to_i16, IO::ByteFormat::BigEndian)
          row.each do |cell|
            if cell.nil?
              b.write_bytes(-1_i32, IO::ByteFormat::BigEndian)
            else
              b.write_bytes(cell.bytesize.to_i32, IO::ByteFormat::BigEndian)
              b << cell
            end
          end
        end
      end
      send(io, 'C') { |b| b << "SELECT #{rows.size}" << '\0' }
    else
      send(io, 'E') do |b|
        b << 'S' << "ERROR" << '\0' << 'C' << "42601" << '\0' << 'M' << "no canned result for: #{sql}" << '\0'
        b.write_byte 0_u8
      end
    end
    send(io, 'Z') { |b| b << 'I' }
  end

  private def send(io, type : Char, & : IO::Memory ->)
    body = IO::Memory.new
    yield body
    io.write_byte type.ord.to_u8
    io.write_bytes(body.size.to_i32 + 4, IO::ByteFormat::BigEndian)
    io.write(body.to_slice)
    io.flush
  end
end
```

- [ ] **Step 2: Failing spec `spec/wire/connection_spec.cr`**

```crystal
require "../spec_helper"
require "../support/stub_server"

private VERSION_FIELDS = [NodeDB::Wire::Field.new("server_version", 25, 0_i16)]

private def stub_with(queries)
  base = {"SHOW server_version" => {VERSION_FIELDS, [["NodeDB 0.4.0"] of String?]}}
  StubServer.new(base.merge(queries))
end

describe NodeDB::Wire::Connection do
  it "connects (trust), queries, and decodes rows" do
    server = stub_with({
      "SELECT 1" => {[NodeDB::Wire::Field.new("n", 23, 0_i16)], [["1"] of String?]},
    })
    conn = NodeDB::Wire::Connection.new("127.0.0.1", server.port, user: "u", database: "d")
    result = conn.query("SELECT 1")
    result.fields.map(&.name).should eq(["n"])
    result.rows.size.should eq(1)
    String.new(result.rows[0][0].not_nil!).should eq("1")
    result.command_tag.should eq("SELECT 1")
    conn.close
    server.close
  end

  it "decodes NULL cells" do
    server = stub_with({
      "SELECT x" => {[NodeDB::Wire::Field.new("x", 25, 0_i16)], [[nil] of String?]},
    })
    conn = NodeDB::Wire::Connection.new("127.0.0.1", server.port, user: "u", database: "d")
    conn.query("SELECT x").rows[0][0].should be_nil
    conn.close
    server.close
  end

  it "raises QueryError with sqlstate on ErrorResponse and stays usable" do
    server = stub_with({
      "SELECT 1" => {[NodeDB::Wire::Field.new("n", 23, 0_i16)], [["1"] of String?]},
    })
    conn = NodeDB::Wire::Connection.new("127.0.0.1", server.port, user: "u", database: "d")
    error = expect_raises(NodeDB::QueryError) { conn.query("BROKEN") }
    error.sqlstate.should eq("42601")
    conn.query("SELECT 1").rows.size.should eq(1) # connection survived (drained to Z)
    conn.close
    server.close
  end

  it "close is idempotent" do
    server = stub_with({} of String => {Array(NodeDB::Wire::Field), Array(StubServer::Row)})
    conn = NodeDB::Wire::Connection.new("127.0.0.1", server.port, user: "u", database: "d")
    conn.close
    conn.close
    server.close
  end
end
```

- [ ] **Step 3: Run to verify fail.**

- [ ] **Step 4: Write `src/nodedb/wire/connection.cr`**

```crystal
require "socket"

module NodeDB
  module Wire
    record Result, fields : Array(Field), rows : Array(Array(Bytes?)), command_tag : String

    # A single pgwire connection: startup, trust/SCRAM auth, simple queries.
    class Connection
      MIN_SERVER_VERSION = SemanticVersion.new(0, 4, 0)

      @socket : TCPSocket
      @closed = false

      def initialize(host : String, port : Int32, user : String, database : String,
                     password : String? = nil)
        @socket = TCPSocket.new(host, port)
        @socket.sync = false
        Frame.write_startup(@socket, user: user, database: database)
        authenticate(user, password)
        wait_ready
        check_server_version
      rescue e : Socket::ConnectError
        raise ConnectionError.new("cannot connect to #{host}:#{port}: #{e.message}")
      end

      def query(sql : String) : Result
        raise ConnectionError.new("connection is closed") if @closed
        Frame.write_query(@socket, sql)
        fields = [] of Field
        rows = [] of Array(Bytes?)
        command_tag = ""
        error : QueryError? = nil

        loop do
          type, body = Frame.read(@socket)
          case type
          when 'T' then fields = Frame.parse_row_description(body)
          when 'D' then rows << Frame.parse_data_row(body)
          when 'C' then command_tag = String.new(body[0, body.size - 1]) if command_tag.empty?
          when 'E'
            parsed = Frame.parse_error(body)
            error ||= QueryError.new(parsed[:message], parsed[:code])
          when 'Z'
            break
          when 'I', 'N', 'S'
            # empty query / notice / parameter status: ignore
          end
        end

        raise error if error
        Result.new(fields, rows, command_tag)
      end

      def close : Nil
        return if @closed
        @closed = true
        Frame.write_terminate(@socket) rescue nil
        @socket.close rescue nil
      end

      private def authenticate(user : String, password : String?) : Nil
        loop do
          type, body = Frame.read(@socket)
          case type
          when 'R'
            case code = Frame.parse_auth_code(body)
            when 0 then return
            when 10 then sasl_handshake(user, password, String.new(Frame.auth_payload(body)))
            when 11, 12
              raise ConnectionError.new("unexpected SASL continuation outside handshake")
            else
              raise ConnectionError.new("unsupported auth method (code #{code}); nodedb.cr supports trust and SCRAM-SHA-256")
            end
          when 'E'
            parsed = Frame.parse_error(body)
            raise ConnectionError.new("authentication failed: #{parsed[:message]}")
          else
            # ParameterStatus / BackendKeyData may arrive before ready
          end
        end
      end

      private def sasl_handshake(user : String, password : String?, mechanisms : String) : Nil
        unless mechanisms.split('\0').includes?("SCRAM-SHA-256")
          raise ConnectionError.new("server offers no SCRAM-SHA-256 (got: #{mechanisms.gsub('\0', ' ').strip})")
        end
        raise ConnectionError.new("server requires a password (SCRAM-SHA-256)") unless password

        scram = Scram.new(user: user, password: password)
        Frame.write_sasl_initial(@socket, "SCRAM-SHA-256", scram.client_first)

        type, body = Frame.read(@socket)
        raise_auth_error(type, body, expected: "SASL continue")
        unless Frame.parse_auth_code(body) == 11
          raise ConnectionError.new("expected SASL continue, got auth code #{Frame.parse_auth_code(body)}")
        end
        Frame.write_sasl_response(@socket, scram.client_final(String.new(Frame.auth_payload(body))))

        type, body = Frame.read(@socket)
        raise_auth_error(type, body, expected: "SASL final")
        unless Frame.parse_auth_code(body) == 12
          raise ConnectionError.new("expected SASL final, got auth code #{Frame.parse_auth_code(body)}")
        end
        scram.verify_server_final(String.new(Frame.auth_payload(body)))
        # AuthenticationOk (R/0) follows; consumed by the authenticate loop.
      end

      private def raise_auth_error(type : Char, body : Bytes, expected : String) : Nil
        return unless type == 'E'
        parsed = Frame.parse_error(body)
        raise ConnectionError.new("authentication failed (#{expected}): #{parsed[:message]}")
      end

      private def wait_ready : Nil
        loop do
          type, _body = Frame.read(@socket)
          break if type == 'Z'
        end
      end

      private def check_server_version : Nil
        result = query("SHOW server_version")
        raw = result.rows.dig?(0, 0)
        return unless raw
        text = String.new(raw)
        if match = text.match(/(\d+)\.(\d+)\.(\d+)/)
          version = SemanticVersion.new(match[1].to_i, match[2].to_i, match[3].to_i)
          if version < MIN_SERVER_VERSION
            STDERR.puts "nodedb.cr: server reports #{text.inspect} — below the minimum supported NodeDB 0.4.0; expect silent misbehavior (0.3.0 drops parameters and types)"
          end
        end
      rescue QueryError
        # server without SHOW server_version — nothing to check
      end
    end
  end
end
```

Add require to `src/nodedb.cr` (after scram).

- [ ] **Step 5: Run to verify pass**, full suite + format.

- [ ] **Step 6: Live sanity check against the Task 1 container**

Write a throwaway script `/tmp/wire_check.cr` (not committed):

```crystal
require "/home/system/rnd/crystal/nodedb.cr/src/nodedb"

conn = NodeDB::Wire::Connection.new("127.0.0.1", 16432,
  user: ENV["NODEDB_USER"]? || "nodedb",
  database: ENV["NODEDB_DB"]? || "nodedb",
  password: ENV["NODEDB_PASSWORD"]?)
puts conn.query("SELECT 1+1 AS r").rows.map { |row| row.map { |c| c && String.new(c) } }
conn.close
```

Run: `crystal run /tmp/wire_check.cr` → `[["2"]]`. If auth or frames misbehave, fix Wire against reality and update `docs/wire-facts.md` with what differed.

- [ ] **Step 7: Commit** — `git add -A && git commit -m "Add Wire::Connection: trust+SCRAM auth, simple queries, stub-server specs"`

---

### Task 12: `NodeDB::TypeMap`

**Files:**
- Create: `src/nodedb/type_map.cr`, `spec/type_map_spec.cr`
- Modify: `src/nodedb.cr` (require)

**Interfaces:**
- Consumes: `Wire::Field`.
- Produces (Tasks 13–14 consume):
  - `alias NodeDB::Value = String | Int16 | Int32 | Int64 | Float32 | Float64 | Bool | Time | JSON::Any | Array(Float32) | Array(Float64) | Bytes | Nil`
  - `NodeDB::TypeMap.decode(field : Wire::Field, raw : Bytes?) : Value` — text-format decode by OID; binary-format (`field.format == 1`) cells return raw `Bytes` untouched; unknown OIDs → `String`
  - `NodeDB::TypeMap.resolve(nodedb_type : String) : {String, Int32}` — NodeDB type name → {pg type name, oid}, `VARCHAR(255)` → base lookup, unknown → `{"text", 25}` (port of ruby `TypeMap.resolve`; Schema consumes it)

OID table (from ruby MAP + spike): 16 bool · 20 int8 · 21 int2 · 23 int4 · 25 text · 114 json · 700 float4 · 701 float8 · 1043 varchar · 1082 date · 1114 timestamp · 1184 timestamptz · 1700 numeric (**decoded as String** — no BigDecimal in DB::Any; documented) · 2950 uuid (String) · 3802 jsonb · 1021 float4[] → `Array(Float32)` · 1022 float8[] → `Array(Float64)`.

Timestamp text per spike (`docs/wire-facts.md`); parser tries, in order: `%F %T.%N`, `%F %T`, RFC 3339. Array text: pg-standard `{0.1,0.2}` — if `docs/wire-facts.md` recorded a different serialization, adjust `parse_float_array` and its spec to the recorded form.

- [ ] **Step 1: Failing spec `spec/type_map_spec.cr`**

```crystal
require "../spec_helper"

private def field(oid, format = 0_i16)
  NodeDB::Wire::Field.new("c", oid, format)
end

private def decode(oid, text)
  NodeDB::TypeMap.decode(field(oid), text.to_slice)
end

describe NodeDB::TypeMap do
  it "decodes scalars from text" do
    decode(23, "42").should eq(42)
    decode(20, "9000000000").should eq(9_000_000_000_i64)
    decode(21, "7").should eq(7_i16)
    decode(701, "1.5").should eq(1.5)
    decode(700, "0.5").should eq(0.5_f32)
    decode(16, "t").should be_true
    decode(16, "f").should be_false
    decode(25, "hello").should eq("hello")
  end

  it "decodes NULL" do
    NodeDB::TypeMap.decode(field(23), nil).should be_nil
  end

  it "decodes timestamps" do
    decode(1114, "2026-07-23 10:00:00").should eq(Time.utc(2026, 7, 23, 10, 0, 0))
    decode(1114, "2026-07-23 10:00:00.123456").as(Time).nanosecond.should eq(123_456_000)
  end

  it "decodes json and jsonb" do
    decode(114, %({"a":1})).as(JSON::Any)["a"].should eq(1)
    decode(3802, %([1,2])).as(JSON::Any)[0].should eq(1)
  end

  it "decodes float arrays (vectors)" do
    decode(1021, "{0.1,0.2}").should eq([0.1_f32, 0.2_f32])
    decode(1022, "{0.1,0.2,0.3}").should eq([0.1, 0.2, 0.3])
    decode(1022, "{}").should eq([] of Float64)
  end

  it "decodes numeric and unknown OIDs as String" do
    decode(1700, "12.34").should eq("12.34")
    decode(999999, "whatever").should eq("whatever")
  end

  it "passes binary-format cells through as Bytes" do
    raw = Bytes[1, 2, 3]
    NodeDB::TypeMap.decode(NodeDB::Wire::Field.new("c", 23, 1_i16), raw).should eq(raw)
  end

  it "resolves NodeDB type names (Schema support)" do
    NodeDB::TypeMap.resolve("TEXT").should eq({"text", 25})
    NodeDB::TypeMap.resolve("VARCHAR(255)").should eq({"character varying", 1043})
    NodeDB::TypeMap.resolve("wat").should eq({"text", 25})
  end
end
```

- [ ] **Step 2: Run to verify fail.**

- [ ] **Step 3: Write `src/nodedb/type_map.cr`**

```crystal
require "json"

module NodeDB
  alias Value = String | Int16 | Int32 | Int64 | Float32 | Float64 | Bool | Time | JSON::Any | Array(Float32) | Array(Float64) | Bytes | Nil

  # Text-format decoding by OID, plus NodeDB-type-name resolution (Schema).
  # Unknown OIDs decode as String — never raise on a type we don't know.
  module TypeMap
    TIMESTAMP_FORMATS = ["%F %T.%N", "%F %T"]

    NAME_MAP = {
      "TEXT" => {"text", 25}, "VARCHAR" => {"character varying", 1043},
      "FLOAT" => {"double precision", 701}, "FLOAT4" => {"real", 700},
      "FLOAT8" => {"double precision", 701}, "DOUBLE" => {"double precision", 701},
      "INTEGER" => {"integer", 23}, "INT" => {"integer", 23}, "INT4" => {"integer", 23},
      "INT2" => {"smallint", 21}, "SMALLINT" => {"smallint", 21},
      "INT8" => {"bigint", 20}, "BIGINT" => {"bigint", 20},
      "BOOLEAN" => {"boolean", 16}, "BOOL" => {"boolean", 16},
      "TIMESTAMP" => {"timestamp without time zone", 1114},
      "TIMESTAMP TIME_KEY" => {"timestamp without time zone", 1114},
      "TIMESTAMPTZ" => {"timestamp with time zone", 1184},
      "DATE" => {"date", 1082}, "UUID" => {"uuid", 2950},
      "JSON" => {"json", 114}, "JSONB" => {"jsonb", 3802},
      "NUMERIC" => {"numeric", 1700}, "DECIMAL" => {"numeric", 1700},
      "BYTEA" => {"bytea", 17},
    }

    def self.decode(field : Wire::Field, raw : Bytes?) : Value
      return nil if raw.nil?
      return raw if field.format == 1 # binary passthrough — we never request it

      text = String.new(raw)
      case field.oid
      when 16         then text == "t" || text == "true"
      when 21         then text.to_i16
      when 23         then text.to_i32
      when 20         then text.to_i64
      when 700        then text.to_f32
      when 701        then text.to_f64
      when 114, 3802  then JSON.parse(text)
      when 1114, 1184 then parse_time(text)
      when 1082       then Time.parse_utc(text, "%F")
      when 1021       then parse_float_array(text, &.to_f32)
      when 1022       then parse_float_array(text, &.to_f64)
      else                 text
      end
    end

    def self.resolve(nodedb_type : String) : {String, Int32}
      base = nodedb_type.upcase.split('(').first.strip
      NAME_MAP[base]? || {"text", 25}
    end

    private def self.parse_time(text : String) : Time
      TIMESTAMP_FORMATS.each do |format|
        return Time.parse_utc(text, format)
      rescue Time::Format::Error
        next
      end
      Time.parse_rfc3339(text)
    end

    private def self.parse_float_array(text : String, & : String -> T) : Array(T) forall T
      inner = text.strip.lchop('{').rchop('}')
      return [] of T if inner.empty?
      inner.split(',').map { |part| yield part.strip }
    end
  end
end
```

Add require to `src/nodedb.cr`.

- [ ] **Step 4: Run to verify pass**, full suite + format.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "Add TypeMap: text decode by OID + type-name resolution"`

---

### Task 13: crystal-db driver

**Files:**
- Create: `src/nodedb/driver.cr`, `spec/driver_spec.cr`
- Modify: `src/nodedb.cr` (require last, after all wire/typemap requires)

**Interfaces:**
- Consumes: `Wire::Connection`, `Wire::Result`, `TypeMap.decode`, `SQL::Quoting.literal`.
- Produces: `DB.open("nodedb://user[:pass]@host:6432/dbname")` works end-to-end; `NodeDB::Driver`, `NodeDB::Connection < DB::Connection`, `NodeDB::Statement < DB::Statement`, `NodeDB::ResultSet < DB::ResultSet`. Registered scheme: `"nodedb"`. Args: `$1..$n` placeholders substituted client-side via `Quoting.literal` (documented limitation: placeholders inside string literals are also substituted — don't put `$n` in literals).

- [ ] **Step 1: Failing spec `spec/driver_spec.cr`** (uses StubServer — no real NodeDB needed)

```crystal
require "./spec_helper"
require "./support/stub_server"

private VERSION_FIELDS = [NodeDB::Wire::Field.new("server_version", 25, 0_i16)]

private def stub_with(queries)
  base = {"SHOW server_version" => {VERSION_FIELDS, [["NodeDB 0.4.0"] of String?]}}
  StubServer.new(base.merge(queries))
end

describe NodeDB::Driver do
  it "opens via DB.open and queries typed values" do
    server = stub_with({
      "SELECT n, name FROM t" => {
        [NodeDB::Wire::Field.new("n", 23, 0_i16), NodeDB::Wire::Field.new("name", 25, 0_i16)],
        [["1", "alice"] of String?, ["2", nil] of String?],
      },
    })
    DB.open("nodedb://u@127.0.0.1:#{server.port}/d") do |db|
      names = [] of String
      ns = [] of Int32
      db.query("SELECT n, name FROM t") do |rs|
        rs.each do
          ns << rs.read(Int32)
          names << (rs.read(String?) || "-")
        end
      end
      ns.should eq([1, 2])
      names.should eq(["alice", "-"])
    end
    server.close
  end

  it "substitutes $n args via Quoting" do
    server = stub_with({
      "SELECT * FROM t WHERE id = 'o''brien' AND n = 42" => {
        [NodeDB::Wire::Field.new("ok", 16, 0_i16)], [["t"] of String?],
      },
    })
    DB.open("nodedb://u@127.0.0.1:#{server.port}/d") do |db|
      db.query_one("SELECT * FROM t WHERE id = $1 AND n = $2", "o'brien", 42, as: Bool).should be_true
    end
    server.close
  end

  it "raises QueryError for server errors" do
    server = stub_with({} of String => {Array(NodeDB::Wire::Field), Array(StubServer::Row)})
    DB.open("nodedb://u@127.0.0.1:#{server.port}/d") do |db|
      expect_raises(NodeDB::QueryError) { db.exec("BROKEN") }
    end
    server.close
  end

  it "exec returns rows_affected from the command tag" do
    server = stub_with({
      "DELETE FROM t" => {[] of NodeDB::Wire::Field, [] of StubServer::Row},
    })
    DB.open("nodedb://u@127.0.0.1:#{server.port}/d") do |db|
      db.exec("DELETE FROM t") # StubServer tags "SELECT 0"; just verify no raise
    end
    server.close
  end
end
```

- [ ] **Step 2: Run to verify fail.**

- [ ] **Step 3: Write `src/nodedb/driver.cr`**

```crystal
require "db"

module NodeDB
  class Driver < ::DB::Driver
    class ConnectionBuilder < ::DB::ConnectionBuilder
      def initialize(@options : ::DB::Connection::Options, @uri : URI)
      end

      def build : ::DB::Connection
        Connection.new(@options, @uri)
      end
    end

    def connection_builder(uri : URI) : ::DB::ConnectionBuilder
      params = HTTP::Params.parse(uri.query || "")
      ConnectionBuilder.new(connection_options(params), uri)
    end
  end

  class Connection < ::DB::Connection
    getter wire : Wire::Connection

    def initialize(options : ::DB::Connection::Options, uri : URI)
      super(options)
      @wire = Wire::Connection.new(
        host: uri.hostname || "localhost",
        port: uri.port || 6432,
        user: uri.user || raise(ConnectionError.new("nodedb:// URI requires a user")),
        database: uri.path.lchop('/').presence || raise(ConnectionError.new("nodedb:// URI requires a database")),
        password: uri.password,
      )
    end

    def build_prepared_statement(query) : ::DB::Statement
      # No server-side prepare on the simple protocol; args are inlined.
      Statement.new(self, query)
    end

    def build_unprepared_statement(query) : ::DB::Statement
      Statement.new(self, query)
    end

    protected def do_close
      @wire.close
    end
  end

  class Statement < ::DB::Statement
    def initialize(connection : Connection, command : String)
      super(connection, command)
    end

    protected def conn : Wire::Connection
      connection.as(Connection).wire
    end

    protected def perform_query(args : Enumerable) : ::DB::ResultSet
      ResultSet.new(self, conn.query(substitute(command, args)))
    end

    protected def perform_exec(args : Enumerable) : ::DB::ExecResult
      result = conn.query(substitute(command, args))
      ::DB::ExecResult.new(rows_affected(result.command_tag), 0_i64)
    end

    # Client-side $n substitution. Simple protocol has no binds; values are
    # rendered through Quoting. Known limitation: $n inside string literals
    # is substituted too — keep placeholders out of literals.
    private def substitute(sql : String, args : Enumerable) : String
      list = args.to_a
      return sql if list.empty?
      sql.gsub(/\$(\d+)/) do |match|
        index = $1.to_i
        raise ArgumentError.new("no argument for placeholder #{match}") if index < 1 || index > list.size
        SQL::Quoting.literal(cast_arg(list[index - 1]))
      end
    end

    private def cast_arg(value)
      case value
      when String, Int32, Int64, Float32, Float64, Bool, Time, Nil,
           Array(Float32), Array(Float64)
        value
      when Int   then value.to_i64
      when Float then value.to_f64
      else
        raise ArgumentError.new("unsupported argument type: #{value.class}")
      end
    end

    private def rows_affected(tag : String) : Int64
      tag.split(' ').last?.try(&.to_i64?) || 0_i64
    end
  end

  class ResultSet < ::DB::ResultSet
    @row : Array(Bytes?)?
    @row_index = -1
    @column_index = 0

    def initialize(statement : ::DB::Statement, @result : Wire::Result)
      super(statement)
    end

    def move_next : Bool
      @row_index += 1
      @column_index = 0
      if @row_index < @result.rows.size
        @row = @result.rows[@row_index]
        true
      else
        @row = nil
        false
      end
    end

    def read
      row = @row || raise QueryError.new("read without move_next")
      field = @result.fields[@column_index]
      raw = row[@column_index]
      @column_index += 1
      TypeMap.decode(field, raw)
    end

    def column_count : Int32
      @result.fields.size
    end

    def column_name(index : Int32) : String
      @result.fields[index].name
    end

    protected def do_close
    end
  end
end

DB.register_driver "nodedb", NodeDB::Driver
```

Add `require "./nodedb/driver"` as the last require in `src/nodedb.cr`.

- [ ] **Step 4: Run to verify pass.** If crystal-db 0.13's abstract API differs from the above (compile errors name the exact missing/mismatched methods), consult `lib/db/src/db/` (vendored by shards) and adapt `Connection/Statement/ResultSet` overrides to the abstract defs — the Wire/TypeMap seams stay unchanged.

- [ ] **Step 5: Full suite + format, then live check** — rerun `/tmp/wire_check.cr` equivalent through the driver:

```crystal
require "/home/system/rnd/crystal/nodedb.cr/src/nodedb"
DB.open("nodedb://#{ENV["NODEDB_USER"]? || "nodedb"}@127.0.0.1:16432/#{ENV["NODEDB_DB"]? || "nodedb"}") do |db|
  puts db.query_one("SELECT 1+1", as: Int32) # => 2
end
```

- [ ] **Step 6: Commit** — `git add -A && git commit -m "Add crystal-db driver: nodedb:// scheme over Wire"`

---

### Task 14: `NodeDB::Schema`

**Files:**
- Create: `src/nodedb/schema.cr`, `spec/schema_spec.cr`
- Modify: `src/nodedb.cr` (require before driver)

**Interfaces:**
- Consumes: `SQL::Collection.describe/show`, `TypeMap.resolve`, `DB::Database#query`.
- Produces:
  - `record NodeDB::Schema::Column, name : String, type : String, pg_type : String, oid : Int32, nullable : Bool, primary_key : Bool`
  - `Schema.normalize(rows : Array(Hash(String, String)), internal : Bool = false) : Array(Column)` — pure; ports ruby's quirk handling: duplicate rows per PK column (one carries `PRIMARY KEY` in type), `__`-prefixed internal columns hidden unless `internal`
  - `Schema.columns(db : DB::Database | DB::Connection, collection : String, internal : Bool = false) : Array(Column)` — runs DESCRIBE, feeds normalize; DESCRIBE result columns are `field`, `type`, `nullable`
  - `Schema.collections(db : DB::Database | DB::Connection) : Array(String)` — SHOW COLLECTIONS, `name` column

- [ ] **Step 1: Failing spec `spec/schema_spec.cr`** (normalize is pure — no server)

```crystal
require "./spec_helper"

private def row(field, type, nullable = "true")
  {"field" => field, "type" => type, "nullable" => nullable}
end

describe NodeDB::Schema do
  it "normalizes DESCRIBE rows with PK duplicates" do
    rows = [
      row("id", "TEXT PRIMARY KEY", "false"),
      row("id", "TEXT", "false"),
      row("total", "NUMERIC"),
    ]
    cols = NodeDB::Schema.normalize(rows)
    cols.size.should eq(2)
    id = cols.find! { |c| c.name == "id" }
    id.primary_key.should be_true
    id.type.should eq("TEXT")
    id.pg_type.should eq("text")
    id.oid.should eq(25)
    id.nullable.should be_false
    total = cols.find! { |c| c.name == "total" }
    total.primary_key.should be_false
    total.nullable.should be_true
    total.oid.should eq(1700)
  end

  it "hides __internal columns unless internal: true" do
    rows = [row("__v", "INT"), row("x", "TEXT")]
    NodeDB::Schema.normalize(rows).map(&.name).should eq(["x"])
    NodeDB::Schema.normalize(rows, internal: true).map(&.name).should eq(["__v", "x"])
  end
end
```

- [ ] **Step 2: Run to verify fail.**

- [ ] **Step 3: Write `src/nodedb/schema.cr`**

```crystal
module NodeDB
  # Typed introspection over DESCRIBE / SHOW COLLECTIONS. Normalizes the raw
  # DESCRIBE quirks: duplicate rows for the primary-key column (one carries
  # "PRIMARY KEY" in the type) and __-prefixed internal columns.
  module Schema
    record Column, name : String, type : String, pg_type : String, oid : Int32,
      nullable : Bool, primary_key : Bool

    def self.columns(db, collection : String, internal : Bool = false) : Array(Column)
      rows = [] of Hash(String, String)
      db.query(SQL::Collection.describe(collection)) do |rs|
        rs.each do
          row = {} of String => String
          rs.column_count.times do |i|
            row[rs.column_name(i)] = rs.read.to_s
          end
          rows << row
        end
      end
      normalize(rows, internal: internal)
    end

    def self.normalize(rows : Array(Hash(String, String)), internal : Bool = false) : Array(Column)
      rows = rows.reject { |r| r["field"].starts_with?("__") } unless internal

      rows.group_by { |r| r["field"] }.map do |field, dups|
        primary = dups.any? { |r| r["type"].upcase.includes?("PRIMARY KEY") }
        raw_type = dups.first["type"].sub(/\s+PRIMARY KEY\z/i, "")
        pg_type, oid = TypeMap.resolve(raw_type)
        nullable = !primary && dups.all? { |r| r["nullable"]? == "true" }
        Column.new(field, raw_type, pg_type, oid, nullable, primary)
      end
    end

    def self.collections(db) : Array(String)
      names = [] of String
      db.query(SQL::Collection.show) do |rs|
        rs.each do
          rs.column_count.times do |i|
            value = rs.read
            names << value.to_s if rs.column_name(i) == "name"
          end
        end
      end
      names
    end
  end
end
```

Add require to `src/nodedb.cr` (before driver).

- [ ] **Step 4: Run to verify pass**, full suite + format.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "Add Schema introspection over DESCRIBE/SHOW COLLECTIONS"`

---

### Task 15: Integration suite + CI service

**Files:**
- Create: `spec/integration/end_to_end_spec.cr`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: everything. Collections are created `nodedb_cr_spec_*` and dropped in `ensure` blocks so reruns are clean.

- [ ] **Step 1: Write `spec/integration/end_to_end_spec.cr`** (all examples go through `with_nodedb` — pending without `NODEDB_URL`)

```crystal
require "../spec_helper"

describe "nodedb.cr end-to-end", tags: "integration" do
  it "round-trips typed scalars" do
    with_nodedb do |db|
      db.query_one("SELECT 1+1", as: Int32).should eq(2)
    end
  end

  it "creates a collection, inserts, vector-searches, drops" do
    with_nodedb do |db|
      name = "nodedb_cr_spec_vec"
      begin
        db.exec NodeDB::SQL::Collection.create(name,
          columns: ["id TEXT PRIMARY KEY", "emb FLOAT[]"])
        db.exec "INSERT INTO #{name} (id, emb) VALUES ($1, $2)", "a", [0.1, 0.2, 0.3] of Float64
        db.exec "INSERT INTO #{name} (id, emb) VALUES ($1, $2)", "b", [0.9, 0.9, 0.9] of Float64
        sql = NodeDB::SQL::Vector.search(table: name, column: "emb",
          embedding: [0.1, 0.2, 0.3] of Float64, limit: 1)
        ids = [] of String
        db.query(sql) { |rs| rs.each { ids << rs.read(String) } }
        ids.first?.should eq("a")
      ensure
        db.exec NodeDB::SQL::Collection.drop_if_exists(name)
      end
    end
  end

  it "reads back a vector column as Array" do
    with_nodedb do |db|
      name = "nodedb_cr_spec_typed"
      begin
        db.exec NodeDB::SQL::Collection.create(name,
          columns: ["id TEXT PRIMARY KEY", "emb FLOAT[]", "ts TIMESTAMP", "n INT"])
        db.exec "INSERT INTO #{name} (id, emb, ts, n) VALUES ($1, $2, $3, $4)",
          "a", [0.5, 0.25] of Float64, Time.utc(2026, 7, 23, 10, 0, 0), 42
        db.query("SELECT emb, ts, n FROM #{name}") do |rs|
          rs.each do
            emb = rs.read
            emb.should be_a(Array(Float64)) | be_a(Array(Float32))
            rs.read.should be_a(Time)
            rs.read(Int32).should eq(42)
          end
        end
      ensure
        db.exec NodeDB::SQL::Collection.drop_if_exists(name)
      end
    end
  end

  it "runs graph edges + traverse" do
    with_nodedb do |db|
      name = "nodedb_cr_spec_graph"
      begin
        db.exec NodeDB::SQL::Collection.create(name)
        db.exec NodeDB::SQL::Graph.insert_edge(in_collection: name,
          from: "alice", to: "bob", type: "knows")
        result = [] of String
        db.query(NodeDB::SQL::Graph.traverse(from: "alice", depth: 1)) do |rs|
          rs.each { result << rs.read.to_s }
        end
        result.should_not be_empty
      ensure
        db.exec NodeDB::SQL::Collection.drop_if_exists(name)
      end
    end
  end

  it "surfaces server errors as QueryError with sqlstate" do
    with_nodedb do |db|
      error = expect_raises(NodeDB::QueryError) { db.exec("SELECT definitely_not_a_fn()") }
      error.sqlstate.should_not be_nil
    end
  end

  it "introspects schema" do
    with_nodedb do |db|
      name = "nodedb_cr_spec_schema"
      begin
        db.exec NodeDB::SQL::Collection.create(name,
          columns: ["id TEXT PRIMARY KEY", "total NUMERIC"])
        cols = NodeDB::Schema.columns(db, name)
        cols.find! { |c| c.name == "id" }.primary_key.should be_true
        NodeDB::Schema.collections(db).should contain(name)
      ensure
        db.exec NodeDB::SQL::Collection.drop_if_exists(name)
      end
    end
  end
end
```

Note: if any expectation trips on a real-dialect difference (e.g. traverse result shape, FLOAT[] column syntax), fix the SPEC to match reality, record the fact in `docs/wire-facts.md`, and if a builder emitted the wrong SQL, fix the builder + its unit spec in the same commit.

- [ ] **Step 2: Run locally against the Task 1 container**

```bash
NODEDB_URL="nodedb://<USER>@localhost:16432/<DB>" crystal spec --tag integration
```
Expected: all integration examples pass (not pending).

- [ ] **Step 3: Add the CI integration job to `.github/workflows/ci.yml`**

```yaml
  integration:
    runs-on: ubuntu-latest
    services:
      nodedb:
        image: farhansyah/nodedb:<PINNED_TAG>   # same tag as docs/wire-facts.md
        ports: ["16432:6432"]
    steps:
      - uses: actions/checkout@v4
      - uses: crystal-lang/install-crystal@v1
        with: {crystal: latest}
      - run: shards install
      - run: crystal spec --tag integration
        env:
          NODEDB_URL: nodedb://<USER>@localhost:16432/<DB>   # creds from docs/wire-facts.md
```

- [ ] **Step 4: Full suite green** — `crystal spec` (unit) and the tagged integration run both pass; format clean.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "Add end-to-end integration suite + CI service container"`

---

### Task 16: README, docs, v0.1.0

**Files:**
- Create: `README.md`, `CHANGELOG.md`
- Modify: `docs/superpowers/specs/2026-07-23-nodedb-crystal-design.md` (only if reality diverged — keep the spec honest)

- [ ] **Step 1: Write `README.md`** with these sections (mirror nodedb-ruby's README structure so the family reads consistently): title + badges (CI); What is this (2 sentences, link NodeDB + nodedb-ruby as the Ruby sibling); Installation (`shard.yml` snippet); Quick start:

```crystal
require "nodedb"

DB.open("nodedb://nodedb@localhost:6432/nodedb") do |db|
  puts db.query_one("SELECT 1+1", as: Int32)

  db.exec NodeDB::SQL::Collection.create("articles",
    columns: ["id TEXT PRIMARY KEY", "embedding FLOAT[]"])

  db.exec "INSERT INTO articles (id, embedding) VALUES ($1, $2)",
    "intro", [0.1, 0.2, 0.3] of Float64

  sql = NodeDB::SQL::Vector.search(table: "articles", column: "embedding",
    embedding: [0.1, 0.2, 0.3] of Float64, limit: 10)
  db.query(sql) { |rs| rs.each { puts rs.read(String) } }
end
```

Then: one short example per builder module (Graph, FTS, KV, Timeseries, Spatial, Collection — lift inputs/outputs from the unit specs); a Compatibility section (NodeDB ≥ 0.4.0 required, and why: 0.3.0 drops parameters silently; simple query protocol; `$n` args inlined client-side — placeholders-in-literals caveat; auth trust + SCRAM-SHA-256); a Roadmap section (native MessagePack transport, LISTEN/NOTIFY, extended protocol, ORM adapter shards); Development (docker run command from Task 1, `NODEDB_URL=... crystal spec --tag integration`); License (BSD-2-Clause) + a credit line: "API design follows [nodedb-ruby](https://github.com/mkhairi/nodedb-ruby) by @mkhairi."

- [ ] **Step 2: Write `CHANGELOG.md`**

```markdown
# Changelog

## 0.1.0 — 2026-07-XX

Initial release.

- crystal-db driver for the `nodedb://` scheme (pgwire simple query protocol,
  trust + SCRAM-SHA-256 auth, NodeDB >= 0.4.0).
- SQL builders: Vector, Graph, FTS, KV, Timeseries, Spatial, Collection —
  ported from nodedb-ruby with typed args and internal quoting.
- Schema introspection (DESCRIBE / SHOW COLLECTIONS) and text-format TypeMap
  (vectors, JSON, timestamps).
```

- [ ] **Step 3: Spec-vs-reality pass** — reread the design spec; if any wire fact or builder shape changed during implementation, update the spec's affected section and `docs/wire-facts.md`.

- [ ] **Step 4: Final green + format** — `crystal spec` + integration tag + `crystal tool format --check src spec`.

- [ ] **Step 5: Commit + tag**

```bash
git add -A && git commit -m "Add README, CHANGELOG for v0.1.0"
git tag v0.1.0
```
(Pushing to GitHub, shardbox listing, and announcements are eman's call — do not push from here.)

---

## Plan Self-Review (completed)

- **Spec coverage:** Wire (Tasks 9–11), driver (13), seven builders (4–8), Quoting (3), Schema (14), TypeMap (12), integration+CI (15), README/announce prep (16), spike + wire-facts (1), skeleton/license/CI (2). Version gate at connect: Task 11 `check_server_version`. Identifier allowlist: Task 3. Unknown-OID→String: Task 12. ✓
- **Placeholder scan:** no TBDs; the two deliberate adapt-to-reality notes (Task 12 array format, Task 15 dialect trips) each name the exact file, the recorded fact source, and the required same-commit fix. ✓
- **Type consistency:** `Wire::Field(name, oid, format)` used identically in 9/11/12/13; `Result(fields, rows, command_tag)` in 11/13; `QueryError(message, sqlstate)` defined in 2, raised in 11, asserted in 13/15; `Quoting.literal` overload set in 3 matches `cast_arg` whitelist in 13; `TypeMap.resolve` tuple return in 12 matches Schema destructure in 14. ✓
