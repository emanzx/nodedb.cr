module NodeDB
  module SQL
    # Builder for NodeDB vector search (SEARCH ... USING VECTOR).
    module Vector
      # A vector index must exist over `column` before SEARCH returns any
      # rows (verified live against NodeDB 0.4.0 — see docs/wire-facts.md).
      # The column binding MUST use the "(column)" form with a space before
      # the paren: `ON table (column)` binds correctly, `ON table(column)`
      # (no space) and `ON table FIELD column` both parse without error but
      # silently fail to bind (SEARCH then returns 0 rows) — a NodeDB 0.4.0
      # quirk, not a Postgres-compat convention.
      def self.create_index(name : String, table : String, column : String,
                            dim : Int32, metric : String = "cosine") : String
        raise ArgumentError.new("dim must be positive") unless dim.positive?
        "CREATE VECTOR INDEX #{Quoting.identifier(name)} ON #{Quoting.identifier(table)} " \
        "(#{Quoting.identifier(column)}) METRIC #{Quoting.identifier(metric)} DIM #{dim}"
      end

      # `DROP INDEX` (not `DROP VECTOR INDEX` — the latter is rejected by the
      # parser) — mirrors FTS.drop_index. Note: verified live that this
      # reports success but does NOT actually remove the vector index from
      # `SHOW INDEXES` (NodeDB 0.4.0 quirk); harmless for ensure-block
      # best-effort cleanup, see docs/wire-facts.md.
      def self.drop_index(name : String) : String
        "DROP INDEX #{Quoting.identifier(name)}"
      end

      # filter is a raw SQL fragment appended as WHERE — caller-trusted,
      # like nodedb-ruby's filter: kwarg.
      def self.search(table : String, column : String,
                      embedding : Array(Float32) | Array(Float64),
                      limit : Int32, filter : String? = nil) : String
        raise ArgumentError.new("embedding must not be empty") if embedding.empty?
        raise ArgumentError.new("limit must be positive") unless limit.positive?
        sql = String.build do |s|
          s << "SEARCH " << Quoting.identifier(table)
          s << " USING VECTOR(" << Quoting.identifier(column)
          s << ", " << Quoting.literal(embedding) << ", " << limit << ')'
        end
        filter ? "#{sql} WHERE #{filter}" : sql
      end
    end
  end
end
