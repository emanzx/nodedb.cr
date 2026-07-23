module NodeDB
  module Wire
    record Field, name : String, oid : Int32, format : Int16

    # pgwire v3 frame encode/decode. All integers big-endian.
    module Frame
      PROTOCOL_VERSION = 196608 # 3.0

      def self.write_startup(io : IO, user : String, database : String) : Nil
        body = IO::Memory.new
        body.write_bytes(PROTOCOL_VERSION, IO::ByteFormat::BigEndian)
        {"user" => user, "database" => database, "client_encoding" => "UTF8"}.each do |k, v|
          body << k << '\0' << v << '\0'
        end
        body.write_byte 0_u8
        io.write_bytes(body.size.to_i32 + 4, IO::ByteFormat::BigEndian)
        io.write(body.to_slice)
        io.flush
      end

      def self.write_query(io : IO, sql : String) : Nil
        write_typed(io, 'Q') { |b| b << sql << '\0' }
      end

      def self.write_terminate(io : IO) : Nil
        write_typed(io, 'X') { }
      end

      def self.write_sasl_initial(io : IO, mechanism : String, payload : String) : Nil
        write_typed(io, 'p') do |b|
          b << mechanism << '\0'
          b.write_bytes(payload.bytesize.to_i32, IO::ByteFormat::BigEndian)
          b << payload
        end
      end

      def self.write_sasl_response(io : IO, payload : String) : Nil
        write_typed(io, 'p') { |b| b << payload }
      end

      def self.read(io : IO) : {Char, Bytes}
        type = io.read_byte || raise ConnectionError.new("server closed connection")
        begin
          length = io.read_bytes(Int32, IO::ByteFormat::BigEndian)
          body = Bytes.new(length - 4)
          io.read_fully(body)
        rescue IO::EOFError
          raise ConnectionError.new("server closed connection mid-frame")
        end
        {type.chr, body}
      end

      def self.parse_row_description(body : Bytes) : Array(Field)
        io = IO::Memory.new(body)
        Array(Field).new(io.read_bytes(Int16, IO::ByteFormat::BigEndian).to_i) do
          name = read_cstring(io)
          io.read_bytes(Int32, IO::ByteFormat::BigEndian) # table oid
          io.read_bytes(Int16, IO::ByteFormat::BigEndian) # attnum
          oid = io.read_bytes(Int32, IO::ByteFormat::BigEndian)
          io.read_bytes(Int16, IO::ByteFormat::BigEndian) # typlen
          io.read_bytes(Int32, IO::ByteFormat::BigEndian) # typmod
          format = io.read_bytes(Int16, IO::ByteFormat::BigEndian)
          Field.new(name, oid, format)
        end
      end

      def self.parse_data_row(body : Bytes) : Array(Bytes?)
        io = IO::Memory.new(body)
        Array(Bytes?).new(io.read_bytes(Int16, IO::ByteFormat::BigEndian).to_i) do
          len = io.read_bytes(Int32, IO::ByteFormat::BigEndian)
          if len < 0
            nil
          else
            value = Bytes.new(len)
            io.read_fully(value)
            value
          end
        end
      end

      def self.parse_error(body : Bytes) : {severity: String, code: String, message: String}
        severity = code = message = ""
        io = IO::Memory.new(body)
        while (field_type = io.read_byte) && field_type != 0
          value = read_cstring(io)
          case field_type.chr
          when 'S' then severity = value
          when 'C' then code = value
          when 'M' then message = value
          end
        end
        {severity: severity, code: code, message: message}
      end

      def self.parse_auth_code(body : Bytes) : Int32
        IO::ByteFormat::BigEndian.decode(Int32, body[0, 4])
      end

      def self.auth_payload(body : Bytes) : Bytes
        body[4..]
      end

      private def self.write_typed(io : IO, type : Char, & : IO::Memory ->) : Nil
        body = IO::Memory.new
        yield body
        io.write_byte type.ord.to_u8
        io.write_bytes(body.size.to_i32 + 4, IO::ByteFormat::BigEndian)
        io.write(body.to_slice)
        io.flush
      end

      private def self.read_cstring(io : IO) : String
        String.build do |s|
          loop do
            byte = io.read_byte
            raise ConnectionError.new("malformed frame: unterminated string") if byte.nil?
            break if byte == 0
            s.write_byte byte
          end
        end
      end
    end
  end
end
