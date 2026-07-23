require "../spec_helper"

describe NodeDB::SQL::Quoting do
  describe ".identifier" do
    it "accepts valid identifiers unchanged" do
      NodeDB::SQL::Quoting.identifier("articles").should eq("articles")
      NodeDB::SQL::Quoting.identifier("_private2").should eq("_private2")
    end

    it "rejects invalid identifiers" do
      expect_raises(ArgumentError) { NodeDB::SQL::Quoting.identifier("bad name") }
      expect_raises(ArgumentError) { NodeDB::SQL::Quoting.identifier("1starts") }
      expect_raises(ArgumentError) { NodeDB::SQL::Quoting.identifier("a;drop") }
      expect_raises(ArgumentError) { NodeDB::SQL::Quoting.identifier("") }
      expect_raises(ArgumentError) { NodeDB::SQL::Quoting.identifier("émbe") }
    end
  end

  describe ".string" do
    it "single-quotes and doubles embedded quotes" do
      NodeDB::SQL::Quoting.string("alice").should eq("'alice'")
      NodeDB::SQL::Quoting.string("o'brien").should eq("'o''brien'")
      NodeDB::SQL::Quoting.string("it''s").should eq("'it''''s'")
    end

    it "rejects NUL bytes" do
      expect_raises(ArgumentError) { NodeDB::SQL::Quoting.string("a\0b") }
    end
  end

  describe ".literal" do
    it "serializes scalars" do
      NodeDB::SQL::Quoting.literal("x").should eq("'x'")
      NodeDB::SQL::Quoting.literal(42).should eq("42")
      NodeDB::SQL::Quoting.literal(1.5).should eq("1.5")
      NodeDB::SQL::Quoting.literal(true).should eq("TRUE")
      NodeDB::SQL::Quoting.literal(nil).should eq("NULL")
    end

    it "serializes Time as UTC timestamp literal" do
      t = Time.utc(2026, 7, 23, 10, 0, 0)
      NodeDB::SQL::Quoting.literal(t).should eq("'2026-07-23 10:00:00.000000'")
    end

    it "serializes float arrays as ARRAY literals" do
      NodeDB::SQL::Quoting.literal([0.1, 0.2] of Float64).should eq("ARRAY[0.1, 0.2]")
      NodeDB::SQL::Quoting.literal([0.5_f32] of Float32).should eq("ARRAY[0.5]")
    end
  end
end
