module NodeDB
  module SQL
    # Full-text search builders. FTS runs on a document collection with a
    # separate CREATE FULLTEXT INDEX; text_match() filters server-side.
    module FTS
      def self.create_index(name : String, collection : String, column : String) : String
        "CREATE FULLTEXT INDEX #{Quoting.identifier(name)} ON #{Quoting.identifier(collection)} (#{Quoting.identifier(column)})"
      end

      def self.drop_index(name : String) : String
        "DROP INDEX #{Quoting.identifier(name)}"
      end

      def self.search(table : String, column : String, query : String,
                      limit : Int32, fuzzy : Bool = false) : String
        raise ArgumentError.new("limit must be positive") unless limit.positive?
        fuzzy_opts = fuzzy ? ", { fuzzy: true, distance: 2 }" : ""
        "SELECT id FROM #{Quoting.identifier(table)} " \
        "WHERE text_match(#{Quoting.identifier(column)}, #{Quoting.string(query)}#{fuzzy_opts}) " \
        "LIMIT #{limit}"
      end
    end
  end
end
