require "db"

module NodeDB
  class Driver < ::DB::Driver
    class ConnectionBuilder < ::DB::ConnectionBuilder
      def initialize(@options : ::DB::Connection::Options, @uri : URI)
      end

      def build : ::DB::Connection
        Connection.new(@options, @uri)
      end
    end

    def connection_builder(uri : URI) : ::DB::ConnectionBuilder
      params = HTTP::Params.parse(uri.query || "")
      ConnectionBuilder.new(connection_options(params), uri)
    end
  end

  class Connection < ::DB::Connection
    getter wire : Wire::Connection

    def initialize(options : ::DB::Connection::Options, uri : URI)
      super(options)
      @wire = Wire::Connection.new(
        host: uri.hostname || "localhost",
        port: uri.port || 6432,
        user: uri.user || raise(ConnectionError.new("nodedb:// URI requires a user")),
        database: uri.path.lchop('/').presence || raise(ConnectionError.new("nodedb:// URI requires a database")),
        password: uri.password,
      )
    end

    def build_prepared_statement(query) : ::DB::Statement
      # No server-side prepare on the simple protocol; args are inlined.
      Statement.new(self, query)
    end

    def build_unprepared_statement(query) : ::DB::Statement
      Statement.new(self, query)
    end

    protected def do_close
      @wire.close
    end
  end

  class Statement < ::DB::Statement
    def initialize(connection : Connection, command : String)
      super(connection, command)
    end

    protected def conn : Wire::Connection
      connection.as(Connection).wire
    end

    protected def perform_query(args : Enumerable) : ::DB::ResultSet
      ResultSet.new(self, conn.query(substitute(command, args)))
    end

    protected def perform_exec(args : Enumerable) : ::DB::ExecResult
      result = conn.query(substitute(command, args))
      ::DB::ExecResult.new(rows_affected(result.command_tag), 0_i64)
    end

    # Client-side $n substitution. Simple protocol has no binds; values are
    # rendered through Quoting. Known limitation: $n inside string literals
    # is substituted too — keep placeholders out of literals.
    private def substitute(sql : String, args : Enumerable) : String
      list = args.to_a
      return sql if list.empty?
      sql.gsub(/\$(\d+)/) do |match|
        index = $1.to_i
        raise ArgumentError.new("no argument for placeholder #{match}") if index < 1 || index > list.size
        SQL::Quoting.literal(cast_arg(list[index - 1]))
      end
    end

    private def cast_arg(value)
      case value
      when String, Int32, Int64, Float32, Float64, Bool, Time, Nil,
           Array(Float32), Array(Float64)
        value
      when Int   then value.to_i64
      when Float then value.to_f64
      else
        raise ArgumentError.new("unsupported argument type: #{value.class}")
      end
    end

    private def rows_affected(tag : String) : Int64
      tag.split(' ').last?.try(&.to_i64?) || 0_i64
    end
  end

  class ResultSet < ::DB::ResultSet
    @row : Array(Bytes?)?
    @row_index = -1
    @column_index = 0

    def initialize(statement : ::DB::Statement, @result : Wire::Result)
      super(statement)
    end

    def move_next : Bool
      @row_index += 1
      @column_index = 0
      if @row_index < @result.rows.size
        @row = @result.rows[@row_index]
        true
      else
        @row = nil
        false
      end
    end

    def read
      row = @row || raise QueryError.new("read without move_next")
      field = @result.fields[@column_index]
      raw = row[@column_index]
      @column_index += 1
      TypeMap.decode(field, raw)
    end

    def column_count : Int32
      @result.fields.size
    end

    def column_name(index : Int32) : String
      @result.fields[index].name
    end

    # crystal-db 0.14 adds this abstract method (not in the 0.13 API the
    # brief was written against): the column index the *next* #read will
    # consume, used for ColumnTypeMismatchError reporting.
    def next_column_index : Int32
      @column_index
    end

    protected def do_close
    end
  end
end

DB.register_driver "nodedb", NodeDB::Driver
