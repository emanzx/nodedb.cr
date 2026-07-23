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
