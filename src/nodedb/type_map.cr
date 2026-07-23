require "json"

module NodeDB
  alias Value = String | Int16 | Int32 | Int64 | Float32 | Float64 | Bool | Time | JSON::Any | Array(Float32) | Array(Float64) | Bytes | Nil

  # Text-format decoding by OID, plus NodeDB-type-name resolution (Schema).
  # Unknown OIDs decode as String — never raise on a type we don't know.
  module TypeMap
    TIMESTAMP_FORMATS = ["%F %T.%N", "%F %T"]

    NAME_MAP = {
      "TEXT" => {"text", 25}, "VARCHAR" => {"character varying", 1043},
      "FLOAT" => {"double precision", 701}, "FLOAT4" => {"real", 700},
      "FLOAT8" => {"double precision", 701}, "DOUBLE" => {"double precision", 701},
      "INTEGER" => {"integer", 23}, "INT" => {"integer", 23}, "INT4" => {"integer", 23},
      "INT2" => {"smallint", 21}, "SMALLINT" => {"smallint", 21},
      "INT8" => {"bigint", 20}, "BIGINT" => {"bigint", 20},
      "BOOLEAN" => {"boolean", 16}, "BOOL" => {"boolean", 16},
      "TIMESTAMP" => {"timestamp without time zone", 1114},
      "TIMESTAMP TIME_KEY" => {"timestamp without time zone", 1114},
      "TIMESTAMPTZ" => {"timestamp with time zone", 1184},
      "DATE" => {"date", 1082}, "UUID" => {"uuid", 2950},
      "JSON" => {"json", 114}, "JSONB" => {"jsonb", 3802},
      "NUMERIC" => {"numeric", 1700}, "DECIMAL" => {"numeric", 1700},
      "BYTEA" => {"bytea", 17},
    }

    def self.decode(field : Wire::Field, raw : Bytes?) : Value
      return nil if raw.nil?
      return raw if field.format == 1 # binary passthrough — we never request it

      text = String.new(raw)
      case field.oid
      when 16         then text == "t" || text == "true"
      when 21         then text.to_i16
      when 23         then text.to_i32
      when 20         then text.to_i64
      when 700        then text.to_f32
      when 701        then text.to_f64
      when 114, 3802  then JSON.parse(text)
      when 1114, 1184 then parse_time(text)
      when 1082       then Time.parse_utc(text, "%F")
      when 1021       then parse_float_array(text, &.to_f32)
      when 1022       then parse_float_array(text, &.to_f64)
      else                 text
      end
    end

    def self.resolve(nodedb_type : String) : {String, Int32}
      base = nodedb_type.upcase.split('(').first.strip
      NAME_MAP[base]? || {"text", 25}
    end

    # NodeDB 0.4.0 serves FLOAT[] (vector) columns as text (OID 25) containing
    # a JSON array, e.g. ["0.1","0.2","0.3"] (elements may be JSON strings or
    # numbers). Callers that know a column is a vector parse it with this.
    # See docs/wire-facts.md.
    def self.parse_vector(text : String) : Array(Float64)
      parsed = JSON.parse(text)
      array = parsed.as_a? || raise ArgumentError.new("not a JSON array: #{text.inspect}")
      array.map do |element|
        element.as_f? || element.as_i?.try(&.to_f64) ||
          element.as_s?.try(&.to_f64?) ||
          raise ArgumentError.new("non-numeric vector element: #{element.inspect}")
      end
    end

    private def self.parse_time(text : String) : Time
      TIMESTAMP_FORMATS.each do |format|
        return Time.parse_utc(text, format)
      rescue Time::Format::Error
        next
      end
      Time.parse_rfc3339(text)
    end

    private def self.parse_float_array(text : String, & : String -> T) : Array(T) forall T
      inner = text.strip.lchop('{').rchop('}')
      return [] of T if inner.empty?
      inner.split(',').map { |part| yield part.strip }
    end
  end
end
