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
