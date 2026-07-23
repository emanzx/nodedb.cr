module NodeDB
  module SQL
    # Builder for NodeDB vector search (SEARCH ... USING VECTOR).
    module Vector
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
