module NodeDB
  # Typed introspection over DESCRIBE / SHOW COLLECTIONS. Normalizes the raw
  # DESCRIBE quirks: duplicate rows for the primary-key column (one carries
  # "PRIMARY KEY" in the type) and __-prefixed internal columns.
  module Schema
    record Column, name : String, type : String, pg_type : String, oid : Int32,
      nullable : Bool, primary_key : Bool

    def self.columns(db, collection : String, internal : Bool = false) : Array(Column)
      rows = [] of Hash(String, String)
      db.query(SQL::Collection.describe(collection)) do |rs|
        rs.each do
          row = {} of String => String
          rs.column_count.times do |i|
            row[rs.column_name(i)] = rs.read.to_s
          end
          rows << row
        end
      end
      normalize(rows, internal: internal)
    end

    def self.normalize(rows : Array(Hash(String, String)), internal : Bool = false) : Array(Column)
      rows = rows.reject { |r| r["field"].starts_with?("__") } unless internal

      rows.group_by { |r| r["field"] }.map do |field, dups|
        primary = dups.any? { |r| r["type"].upcase.includes?("PRIMARY KEY") }
        raw_type = dups.first["type"].sub(/\s+PRIMARY KEY\z/i, "")
        pg_type, oid = TypeMap.resolve(raw_type)
        nullable = !primary && dups.all? { |r| r["nullable"]? == "true" }
        Column.new(field, raw_type, pg_type, oid, nullable, primary)
      end
    end

    def self.collections(db) : Array(String)
      names = [] of String
      db.query(SQL::Collection.show) do |rs|
        rs.each do
          rs.column_count.times do |i|
            value = rs.read
            names << value.to_s if rs.column_name(i) == "name"
          end
        end
      end
      names
    end
  end
end
