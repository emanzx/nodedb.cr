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

  it "resolves an INT column to the observed wire oid (bigint, not int4)" do
    cols = NodeDB::Schema.normalize([row("n", "INT")])
    n = cols.find! { |c| c.name == "n" }
    n.pg_type.should eq("bigint")
    n.oid.should eq(20)
  end
end
