require "socket"
require "../../src/nodedb"

# Minimal in-process pgwire server for unit-testing Wire::Connection
# without a real NodeDB. Speaks trust auth; serves canned results.
class StubServer
  alias Row = Array(String?)
  getter port : Int32
  @terminates = Atomic(Int32).new(0)

  # queries: sql => {fields, rows} served on match; anything else → ErrorResponse
  def initialize(@queries : Hash(String, {Array(NodeDB::Wire::Field), Array(Row)}))
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    spawn { accept_loop }
  end

  def close
    @server.close
  end

  def terminate_count : Int32
    @terminates.get
  end

  private def accept_loop
    while client = @server.accept?
      spawn handle(client)
    end
  rescue IO::Error
  end

  private def handle(io : TCPSocket)
    # Startup: length + payload (ignore contents, answer trust-ok)
    len = io.read_bytes(Int32, IO::ByteFormat::BigEndian)
    io.skip(len - 4)
    send(io, 'R') { |b| b.write_bytes(0_i32, IO::ByteFormat::BigEndian) }
    send(io, 'S') { |b| b << "server_version" << '\0' << "NodeDB 0.4.0" << '\0' }
    send(io, 'Z') { |b| b << 'I' }

    loop do
      type, body = NodeDB::Wire::Frame.read(io)
      case type
      when 'Q' then serve_query(io, String.new(body[0, body.size - 1]))
      when 'X'
        @terminates.add(1)
        break
      end
    end
  rescue IO::Error
  ensure
    io.close rescue nil
  end

  private def serve_query(io, sql)
    if canned = @queries[sql]?
      fields, rows = canned
      send(io, 'T') do |b|
        b.write_bytes(fields.size.to_i16, IO::ByteFormat::BigEndian)
        fields.each do |f|
          b << f.name << '\0'
          b.write_bytes(0_i32, IO::ByteFormat::BigEndian)
          b.write_bytes(0_i16, IO::ByteFormat::BigEndian)
          b.write_bytes(f.oid, IO::ByteFormat::BigEndian)
          b.write_bytes(0_i16, IO::ByteFormat::BigEndian)
          b.write_bytes(-1_i32, IO::ByteFormat::BigEndian)
          b.write_bytes(f.format, IO::ByteFormat::BigEndian)
        end
      end
      rows.each do |row|
        send(io, 'D') do |b|
          b.write_bytes(row.size.to_i16, IO::ByteFormat::BigEndian)
          row.each do |cell|
            if cell.nil?
              b.write_bytes(-1_i32, IO::ByteFormat::BigEndian)
            else
              b.write_bytes(cell.bytesize.to_i32, IO::ByteFormat::BigEndian)
              b << cell
            end
          end
        end
      end
      send(io, 'C') { |b| b << "SELECT #{rows.size}" << '\0' }
    else
      send(io, 'E') do |b|
        b << 'S' << "ERROR" << '\0' << 'C' << "42601" << '\0' << 'M' << "no canned result for: #{sql}" << '\0'
        b.write_byte 0_u8
      end
    end
    send(io, 'Z') { |b| b << 'I' }
  end

  private def send(io, type : Char, & : IO::Memory ->)
    body = IO::Memory.new
    yield body
    io.write_byte type.ord.to_u8
    io.write_bytes(body.size.to_i32 + 4, IO::ByteFormat::BigEndian)
    io.write(body.to_slice)
    io.flush
  end
end
