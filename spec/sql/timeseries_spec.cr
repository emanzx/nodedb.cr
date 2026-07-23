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
    NodeDB::SQL::Timeseries.epoch_ms(t).should eq(1784782800000_i64)
    NodeDB::SQL::Timeseries.since_clause(t).should eq("timestamp > 1784782800000")
    NodeDB::SQL::Timeseries.until_clause(t).should eq("timestamp <= 1784782800000")
  end
end
