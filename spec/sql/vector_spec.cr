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
