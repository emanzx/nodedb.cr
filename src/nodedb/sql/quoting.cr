module NodeDB
  module SQL
    # The single home of identifier validation and value escaping.
    # Identifiers are validated, NOT double-quoted: NodeDB's SEARCH command
    # rejects quoted identifiers (upstream quirk documented by nodedb-ruby).
    module Quoting
      IDENTIFIER_RE = /\A[A-Za-z_][A-Za-z0-9_]*\z/

      def self.identifier(name : String) : String
        raise ArgumentError.new("invalid identifier: #{name.inspect}") unless IDENTIFIER_RE.matches?(name)
        name
      end

      def self.string(value : String) : String
        raise ArgumentError.new("string literal cannot contain NUL") if value.includes?('\0')
        "'#{value.gsub("'", "''")}'"
      end

      def self.literal(value : String) : String
        string(value)
      end

      def self.literal(value : Int | Float) : String
        value.to_s
      end

      def self.literal(value : Bool) : String
        value ? "TRUE" : "FALSE"
      end

      def self.literal(value : Nil) : String
        "NULL"
      end

      def self.literal(value : Time) : String
        "'#{value.to_utc.to_s("%F %T.%6N")}'"
      end

      def self.literal(value : Array(Float32) | Array(Float64)) : String
        "ARRAY[#{value.map(&.to_f64).join(", ")}]"
      end
    end
  end
end
