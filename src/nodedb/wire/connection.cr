require "socket"
require "semantic_version"

module NodeDB
  module Wire
    record Result, fields : Array(Field), rows : Array(Array(Bytes?)), command_tag : String

    # A single pgwire connection: startup, trust/SCRAM auth, simple queries.
    class Connection
      MIN_SERVER_VERSION = SemanticVersion.new(0, 4, 0)

      @socket : TCPSocket
      @closed = false

      def initialize(host : String, port : Int32, user : String, database : String,
                     password : String? = nil)
        @socket = connect(host, port)
        begin
          @socket.sync = false
          Frame.write_startup(@socket, user: user, database: database)
          authenticate(user, password)
          wait_ready
          check_server_version
        rescue e
          @socket.close rescue nil
          raise e
        end
      end

      private def connect(host : String, port : Int32) : TCPSocket
        TCPSocket.new(host, port)
      rescue e : Socket::ConnectError
        raise ConnectionError.new("cannot connect to #{host}:#{port}: #{e.message}")
      end

      def query(sql : String) : Result
        raise ConnectionError.new("connection is closed") if @closed
        Frame.write_query(@socket, sql)
        fields = [] of Field
        rows = [] of Array(Bytes?)
        command_tag = ""
        error : QueryError? = nil

        loop do
          type, body = Frame.read(@socket)
          case type
          when 'T' then fields = Frame.parse_row_description(body)
          when 'D' then rows << Frame.parse_data_row(body)
          when 'C' then command_tag = String.new(body[0, body.size - 1]) if command_tag.empty?
          when 'E'
            parsed = Frame.parse_error(body)
            error ||= QueryError.new(parsed[:message], parsed[:code])
          when 'Z'
            break
          when 'I', 'N', 'S'
            # empty query / notice / parameter status: ignore
          end
        end

        raise error if error
        Result.new(fields, rows, command_tag)
      end

      def close : Nil
        return if @closed
        @closed = true
        Frame.write_terminate(@socket) rescue nil
        @socket.close rescue nil
      end

      private def authenticate(user : String, password : String?) : Nil
        loop do
          type, body = Frame.read(@socket)
          case type
          when 'R'
            case code = Frame.parse_auth_code(body)
            when 0  then return
            when 10 then sasl_handshake(user, password, String.new(Frame.auth_payload(body)))
            when 11, 12
              raise ConnectionError.new("unexpected SASL continuation outside handshake")
            else
              raise ConnectionError.new("unsupported auth method (code #{code}); nodedb.cr supports trust and SCRAM-SHA-256")
            end
          when 'E'
            parsed = Frame.parse_error(body)
            raise ConnectionError.new("authentication failed: #{parsed[:message]}")
          else
            # ParameterStatus / BackendKeyData may arrive before ready
          end
        end
      end

      private def sasl_handshake(user : String, password : String?, mechanisms : String) : Nil
        unless mechanisms.split('\0').includes?("SCRAM-SHA-256")
          raise ConnectionError.new("server offers no SCRAM-SHA-256 (got: #{mechanisms.gsub('\0', ' ').strip})")
        end
        raise ConnectionError.new("server requires a password (SCRAM-SHA-256)") unless password

        scram = Scram.new(user: user, password: password)
        Frame.write_sasl_initial(@socket, "SCRAM-SHA-256", scram.client_first)

        type, body = Frame.read(@socket)
        raise_auth_error(type, body, expected: "SASL continue")
        unless Frame.parse_auth_code(body) == 11
          raise ConnectionError.new("expected SASL continue, got auth code #{Frame.parse_auth_code(body)}")
        end
        Frame.write_sasl_response(@socket, scram.client_final(String.new(Frame.auth_payload(body))))

        type, body = Frame.read(@socket)
        raise_auth_error(type, body, expected: "SASL final")
        unless Frame.parse_auth_code(body) == 12
          raise ConnectionError.new("expected SASL final, got auth code #{Frame.parse_auth_code(body)}")
        end
        scram.verify_server_final(String.new(Frame.auth_payload(body)))
        # AuthenticationOk (R/0) follows; consumed by the authenticate loop.
      end

      private def raise_auth_error(type : Char, body : Bytes, expected : String) : Nil
        return unless type == 'E'
        parsed = Frame.parse_error(body)
        raise ConnectionError.new("authentication failed (#{expected}): #{parsed[:message]}")
      end

      private def wait_ready : Nil
        loop do
          type, _body = Frame.read(@socket)
          break if type == 'Z'
        end
      end

      private def check_server_version : Nil
        result = query("SHOW server_version")
        raw = result.rows.dig?(0, 0)
        return unless raw
        text = String.new(raw)
        if match = text.match(/(\d+)\.(\d+)\.(\d+)/)
          version = SemanticVersion.new(match[1].to_i, match[2].to_i, match[3].to_i)
          if version < MIN_SERVER_VERSION
            STDERR.puts "nodedb.cr: server reports #{text.inspect} — below the minimum supported NodeDB 0.4.0; expect silent misbehavior (0.3.0 drops parameters and types)"
          end
        end
      rescue QueryError
        # server without SHOW server_version — nothing to check
      end
    end
  end
end
