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
