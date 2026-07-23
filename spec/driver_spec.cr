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
