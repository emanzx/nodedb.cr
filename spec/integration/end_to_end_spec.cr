require "../spec_helper"

# Integration suite against a live NodeDB 0.4.0 container. Pending unless
# NODEDB_URL is set (see spec_helper#with_nodedb). Every dialect deviation
# below was probed live and is recorded in docs/wire-facts.md — this file
# asserts reality, not the brief's original (pre-spike) expectations.
#
# Naming: collection/index names get a random suffix per run (not just a
# fixed "nodedb_cr_spec_*" prefix) because DROP COLLECTION is a soft delete
# with a retention window — recreating a just-dropped name within the same
# window errors ("... was dropped and is within its retention window").
# See docs/wire-facts.md.
describe "nodedb.cr end-to-end", tags: "integration" do
  it "round-trips typed scalars" do
    with_nodedb do |db|
      # Unaliased expressions come back as OID 25 (text), not a numeric OID
      # — SELECT 1+1 is NOT decodable `as: Int32`. See docs/wire-facts.md.
      db.query_one("SELECT 1+1", as: String).to_i.should eq(2)
    end
  end

  it "creates a collection, inserts, vector-searches, drops" do
    with_nodedb do |db|
      name = "nodedb_cr_spec_vec_#{Random.rand(1_000_000)}"
      index = "idx_spec_vec_#{Random.rand(1_000_000)}"
      begin
        db.exec NodeDB::SQL::Collection.create(name,
          columns: ["id TEXT PRIMARY KEY", "emb FLOAT[]"])
        # A vector index over `emb` is required before SEARCH returns any
        # rows — without one, SEARCH parses and runs but always returns 0
        # columns/0 rows (Task 1 spike finding, reconfirmed and root-caused
        # here). See docs/wire-facts.md for the exact binding syntax this
        # depends on.
        db.exec NodeDB::SQL::Vector.create_index(name: index, table: name, column: "emb", dim: 3)
        db.exec "INSERT INTO #{name} (id, emb) VALUES ($1, $2)", "a", [0.1, 0.2, 0.3] of Float64
        db.exec "INSERT INTO #{name} (id, emb) VALUES ($1, $2)", "b", [0.9, 0.9, 0.9] of Float64
        sql = NodeDB::SQL::Vector.search(table: name, column: "emb",
          embedding: [0.1, 0.2, 0.3] of Float64, limit: 1)
        ids = [] of String
        db.query(sql) { |rs| rs.each { ids << rs.read(String) } }
        ids.first?.should eq("a")
      ensure
        # Best-effort: DROP INDEX reports success but was observed live to
        # NOT actually remove the vector index from SHOW INDEXES (NodeDB
        # 0.4.0 quirk) — harmless leak for a throwaway spec collection.
        db.exec NodeDB::SQL::Vector.drop_index(index)
        db.exec NodeDB::SQL::Collection.drop_if_exists(name)
      end
    end
  end

  it "reads back a vector column as a parsed Float64 array" do
    with_nodedb do |db|
      name = "nodedb_cr_spec_typed_#{Random.rand(1_000_000)}"
      begin
        db.exec NodeDB::SQL::Collection.create(name,
          columns: ["id TEXT PRIMARY KEY", "emb FLOAT[]", "ts TIMESTAMP", "n INT"])
        inserted = [0.5, 0.25] of Float64
        db.exec "INSERT INTO #{name} (id, emb, ts, n) VALUES ($1, $2, $3, $4)",
          "a", inserted, Time.utc(2026, 7, 23, 10, 0, 0), 42
        db.query("SELECT emb, ts, n FROM #{name}") do |rs|
          rs.each do
            # FLOAT[] (vector) columns arrive as OID 25 text containing a
            # JSON array (e.g. ["0.5","0.25"]), not a native pg array type
            # — read as String, then parse via TypeMap.parse_vector.
            emb = NodeDB::TypeMap.parse_vector(rs.read(String))
            emb.should eq(inserted)
            rs.read.should be_a(Time)
            # NodeDB's INT DDL keyword is 8-byte on the wire (OID 20,
            # int8-shaped), not Postgres's 4-byte int4 — read as Int64.
            rs.read(Int64).should eq(42_i64)
          end
        end
      ensure
        db.exec NodeDB::SQL::Collection.drop_if_exists(name)
      end
    end
  end

  it "runs graph edges + traverse" do
    with_nodedb do |db|
      name = "nodedb_cr_spec_graph_#{Random.rand(1_000_000)}"
      # GRAPH TRAVERSE has no collection-scoping clause — it walks a
      # database-global node/edge space (confirmed live: edges inserted
      # under one collection are still visible to a traverse issued after
      # that collection is dropped). Random node names keep this spec
      # independent of leftover state from previous runs.
      from_node = "spec_alice_#{Random.rand(1_000_000)}"
      to_node = "spec_bob_#{Random.rand(1_000_000)}"
      begin
        db.exec NodeDB::SQL::Collection.create(name)
        db.exec NodeDB::SQL::Graph.insert_edge(in_collection: name,
          from: from_node, to: to_node, type: "knows")
        result = [] of String
        db.query(NodeDB::SQL::Graph.traverse(from: from_node, depth: 1)) do |rs|
          rs.each { result << rs.read.to_s }
        end
        result.should_not be_empty
        result.first.should contain(to_node)
      ensure
        db.exec NodeDB::SQL::Collection.drop_if_exists(name)
      end
    end
  end

  it "surfaces server errors as QueryError with sqlstate" do
    with_nodedb do |db|
      # SELECT of an unknown function/table does NOT behave like Postgres
      # here: `SELECT definitely_not_a_fn()` succeeds server-side, returning
      # one row with a single NULL column, rather than raising 42883 — so it
      # cannot be used to probe error decoding. A genuinely-missing
      # collection does raise. See docs/wire-facts.md.
      error = expect_raises(NodeDB::QueryError) { db.exec("SELECT * FROM nodedb_cr_spec_nonexistent_xyz") }
      error.sqlstate.should_not be_nil
      error.sqlstate.should eq("42P01")
    end
  end

  it "introspects schema" do
    with_nodedb do |db|
      name = "nodedb_cr_spec_schema_#{Random.rand(1_000_000)}"
      begin
        db.exec NodeDB::SQL::Collection.create(name,
          columns: ["id TEXT PRIMARY KEY", "total NUMERIC", "n INT"])
        db.exec "INSERT INTO #{name} (id, total, n) VALUES ($1, $2, $3)", "a", 1.5, 42
        cols = NodeDB::Schema.columns(db, name)
        cols.find! { |c| c.name == "id" }.primary_key.should be_true
        # INT-family DDL types resolve to NodeDB's actual wire-level integer
        # width — OID 20 (int8/bigint), not Postgres's 4-byte int4 (OID 23).
        # See docs/wire-facts.md ("Fix 2 addendum").
        n_col = cols.find! { |c| c.name == "n" }
        n_col.pg_type.should eq("bigint")
        n_col.oid.should eq(20)
        db.query_one("SELECT n FROM #{name}", as: Int64).should eq(42_i64)
        NodeDB::Schema.collections(db).should contain(name)
      ensure
        db.exec NodeDB::SQL::Collection.drop_if_exists(name)
      end
    end
  end
end
