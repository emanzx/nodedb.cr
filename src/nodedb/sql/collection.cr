module NodeDB
  module SQL
    # Collection DDL builders. `columns` entries are raw "name TYPE [constraints]"
    # fragments (caller-trusted, like nodedb-ruby). Engine "fts" maps to
    # document_strict — the standalone fts engine was removed upstream.
    module Collection
      DEFAULT_COLUMNS = {
        "timeseries" => ["ts TIMESTAMP TIME_KEY", "value FLOAT"],
        "kv"         => ["key TEXT PRIMARY KEY", "value TEXT"],
      }

      def self.create(name : String, engine : String? = nil,
                      columns : Array(String) = [] of String,
                      engine_options : Hash(String, String) = {} of String => String,
                      flags : Array(String) = [] of String) : String
        col_parts = columns.empty? ? (DEFAULT_COLUMNS[engine]? || [] of String) : columns
        body_parts = col_parts + flags.map(&.upcase)

        sql = "CREATE COLLECTION #{Quoting.identifier(name)}"
        sql += " (#{body_parts.join(", ")})" unless body_parts.empty?
        with_clause = build_with_clause(engine, engine_options)
        with_clause ? "#{sql} #{with_clause}" : sql
      end

      def self.drop(name : String) : String
        "DROP COLLECTION #{Quoting.identifier(name)}"
      end

      def self.drop_if_exists(name : String) : String
        "DROP COLLECTION IF EXISTS #{Quoting.identifier(name)}"
      end

      def self.show : String
        "SHOW COLLECTIONS"
      end

      def self.describe(name : String) : String
        "DESCRIBE #{Quoting.identifier(name)}"
      end

      private def self.build_with_clause(engine : String?, opts : Hash(String, String)) : String?
        effective = effective_engine(engine)
        return nil if effective.nil? && opts.empty?

        pairs = [] of String
        pairs << "engine='#{effective}'" if effective
        opts.each do |key, value|
          Quoting.identifier(key)
          pairs << "#{key}='#{value.gsub("'", "''")}'"
        end
        "WITH (#{pairs.join(", ")})"
      end

      private def self.effective_engine(engine : String?) : String?
        return nil if engine.nil? || engine == "document"
        engine == "fts" ? "document_strict" : engine
      end
    end
  end
end
