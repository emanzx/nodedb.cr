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
