require "./spec_helper"

private def field(oid, format = 0_i16)
  NodeDB::Wire::Field.new("c", oid, format)
end

private def decode(oid, text)
  NodeDB::TypeMap.decode(field(oid), text.to_slice)
end

describe NodeDB::TypeMap do
  it "decodes scalars from text" do
    decode(23, "42").should eq(42)
    decode(20, "9000000000").should eq(9_000_000_000_i64)
    decode(21, "7").should eq(7_i16)
    decode(701, "1.5").should eq(1.5)
    decode(700, "0.5").should eq(0.5_f32)
    decode(16, "t").should be_true
    decode(16, "f").should be_false
    decode(25, "hello").should eq("hello")
  end

  it "decodes NULL" do
    NodeDB::TypeMap.decode(field(23), nil).should be_nil
  end

  it "decodes timestamps" do
    decode(1114, "2026-07-23 10:00:00").should eq(Time.utc(2026, 7, 23, 10, 0, 0))
    decode(1114, "2026-07-23 10:00:00.123456").as(Time).nanosecond.should eq(123_456_000)
  end

  it "decodes json and jsonb" do
    decode(114, %({"a":1})).as(JSON::Any)["a"].should eq(1)
    decode(3802, %([1,2])).as(JSON::Any)[0].should eq(1)
  end

  it "decodes float arrays (vectors)" do
    decode(1021, "{0.1,0.2}").should eq([0.1_f32, 0.2_f32])
    decode(1022, "{0.1,0.2,0.3}").should eq([0.1, 0.2, 0.3])
    decode(1022, "{}").should eq([] of Float64)
  end

  it "decodes numeric and unknown OIDs as String" do
    decode(1700, "12.34").should eq("12.34")
    decode(999999, "whatever").should eq("whatever")
  end

  it "passes binary-format cells through as Bytes" do
    raw = Bytes[1, 2, 3]
    NodeDB::TypeMap.decode(NodeDB::Wire::Field.new("c", 23, 1_i16), raw).should eq(raw)
  end

  it "resolves NodeDB type names (Schema support)" do
    NodeDB::TypeMap.resolve("TEXT").should eq({"text", 25})
    NodeDB::TypeMap.resolve("VARCHAR(255)").should eq({"character varying", 1043})
    NodeDB::TypeMap.resolve("wat").should eq({"text", 25})
  end

  it "parses NodeDB vector text (JSON array of strings)" do
    NodeDB::TypeMap.parse_vector(%(["0.1","0.2","0.3"])).should eq([0.1, 0.2, 0.3])
  end

  it "parses vector text with bare JSON numbers" do
    NodeDB::TypeMap.parse_vector("[0.1,0.2]").should eq([0.1, 0.2])
    NodeDB::TypeMap.parse_vector("[]").should eq([] of Float64)
  end

  it "raises on non-vector text" do
    expect_raises(ArgumentError) { NodeDB::TypeMap.parse_vector(%({"a":1})) }
    expect_raises(ArgumentError) { NodeDB::TypeMap.parse_vector(%(["x"])) }
  end
end
