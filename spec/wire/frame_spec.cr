require "../spec_helper"

private def be_bytes(&)
  io = IO::Memory.new
  yield io
  io.to_slice
end

describe NodeDB::Wire::Frame do
  it "writes a startup message" do
    io = IO::Memory.new
    NodeDB::Wire::Frame.write_startup(io, user: "u", database: "d")
    bytes = io.to_slice
    # length = 4 + 4 + "user\0u\0database\0d\0client_encoding\0UTF8\0" + terminator
    len = IO::ByteFormat::BigEndian.decode(Int32, bytes[0, 4])
    len.should eq(bytes.size)
    IO::ByteFormat::BigEndian.decode(Int32, bytes[4, 4]).should eq(196608)
    String.new(bytes[8..]).should eq("user\0u\0database\0d\0client_encoding\0UTF8\0\0")
  end

  it "writes a query frame" do
    io = IO::Memory.new
    NodeDB::Wire::Frame.write_query(io, "SELECT 1")
    bytes = io.to_slice
    bytes[0].should eq('Q'.ord)
    IO::ByteFormat::BigEndian.decode(Int32, bytes[1, 4]).should eq(4 + "SELECT 1".bytesize + 1)
    String.new(bytes[5..]).should eq("SELECT 1\0")
  end

  it "reads a typed frame" do
    raw = be_bytes do |io|
      io.write_byte 'Z'.ord.to_u8
      io.write_bytes(5_i32, IO::ByteFormat::BigEndian)
      io.write_byte 'I'.ord.to_u8
    end
    type, body = NodeDB::Wire::Frame.read(IO::Memory.new(raw))
    type.should eq('Z')
    body.should eq(Bytes['I'.ord.to_u8])
  end

  it "parses RowDescription" do
    body = be_bytes do |io|
      io.write_bytes(1_i16, IO::ByteFormat::BigEndian)
      io << "id" << '\0'
      io.write_bytes(0_i32, IO::ByteFormat::BigEndian)  # table oid
      io.write_bytes(0_i16, IO::ByteFormat::BigEndian)  # attnum
      io.write_bytes(23_i32, IO::ByteFormat::BigEndian) # type oid
      io.write_bytes(4_i16, IO::ByteFormat::BigEndian)  # typlen
      io.write_bytes(-1_i32, IO::ByteFormat::BigEndian) # typmod
      io.write_bytes(0_i16, IO::ByteFormat::BigEndian)  # format = text
    end
    fields = NodeDB::Wire::Frame.parse_row_description(body)
    fields.size.should eq(1)
    fields[0].name.should eq("id")
    fields[0].oid.should eq(23)
    fields[0].format.should eq(0)
  end

  it "parses DataRow with NULL" do
    body = be_bytes do |io|
      io.write_bytes(2_i16, IO::ByteFormat::BigEndian)
      io.write_bytes(2_i32, IO::ByteFormat::BigEndian)
      io << "42"
      io.write_bytes(-1_i32, IO::ByteFormat::BigEndian)
    end
    cols = NodeDB::Wire::Frame.parse_data_row(body)
    cols.size.should eq(2)
    String.new(cols[0].not_nil!).should eq("42")
    cols[1].should be_nil
  end

  it "parses ErrorResponse fields" do
    body = be_bytes do |io|
      io << "SERROR" << '\0' << "C42601" << '\0' << "Msyntax error" << '\0' << '\0'
    end
    err = NodeDB::Wire::Frame.parse_error(body)
    err[:severity].should eq("ERROR")
    err[:code].should eq("42601")
    err[:message].should eq("syntax error")
  end

  it "parses auth code and payload" do
    body = be_bytes do |io|
      io.write_bytes(11_i32, IO::ByteFormat::BigEndian)
      io << "r=abc"
    end
    NodeDB::Wire::Frame.parse_auth_code(body).should eq(11)
    String.new(NodeDB::Wire::Frame.auth_payload(body)).should eq("r=abc")
  end

  it "raises ConnectionError on mid-frame EOF" do
    raw = Bytes['Z'.ord.to_u8, 0_u8, 0_u8, 0_u8, 9_u8] # claims 5 body bytes, has none
    expect_raises(NodeDB::ConnectionError, /mid-frame/) do
      NodeDB::Wire::Frame.read(IO::Memory.new(raw))
    end
  end

  it "raises ConnectionError on a truncated cstring in RowDescription" do
    body = IO::Memory.new
    body.write_bytes(1_i16, IO::ByteFormat::BigEndian)
    body << "id" # no 0 terminator, then body ends
    expect_raises(NodeDB::ConnectionError, /unterminated/) do
      NodeDB::Wire::Frame.parse_row_description(body.to_slice)
    end
  end

  it "writes a terminate frame" do
    io = IO::Memory.new
    NodeDB::Wire::Frame.write_terminate(io)
    io.to_slice.should eq(Bytes['X'.ord.to_u8, 0_u8, 0_u8, 0_u8, 4_u8])
  end

  it "raises ConnectionError on ErrorResponse body missing its terminator" do
    body = IO::Memory.new
    body << 'S' << "ERROR" << '\0' # one field, then body ends with no 0 terminator
    expect_raises(NodeDB::ConnectionError, /unterminated ErrorResponse/) do
      NodeDB::Wire::Frame.parse_error(body.to_slice)
    end
  end

  it "raises ConnectionError on a hostile frame length" do
    raw = Bytes['Z'.ord.to_u8, 0_u8, 0_u8, 0_u8, 0_u8] # length 0 < 4
    expect_raises(NodeDB::ConnectionError, /invalid frame length/) do
      NodeDB::Wire::Frame.read(IO::Memory.new(raw))
    end
  end
end
