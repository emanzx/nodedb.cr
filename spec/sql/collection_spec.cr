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
