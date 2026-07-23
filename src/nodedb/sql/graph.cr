require "json"

module NodeDB
  module SQL
    # Builders for NodeDB graph operations (GRAPH INSERT/TRAVERSE/ALGO/DELETE,
    # SHOW GRAPH STATS). The IN <collection> clause is required by current
    # upstream syntax for edge insert/delete.
    module Graph
      alias PropValue = String | Int32 | Int64 | Float64 | Bool | Nil
      alias AlgoValue = String | Int32 | Int64 | Float64 | Bool | Array(String) | Hash(String, Float64)

      enum Direction
        Both
        Inbound
        Outbound
      end

      def self.insert_edge(in_collection : String, from : String, to : String, type : String,
                           properties : Hash(String, PropValue) = {} of String => PropValue) : String
        String.build do |s|
          s << "GRAPH INSERT EDGE IN " << Quoting.identifier(in_collection)
          s << " FROM " << Quoting.string(from) << " TO " << Quoting.string(to)
          s << " TYPE " << Quoting.string(type)
          s << " PROPERTIES " << Quoting.string(properties.to_json)
        end
      end

      def self.traverse(from : String, depth : Int32, direction : Direction = :both) : String
        sql = "GRAPH TRAVERSE FROM #{Quoting.string(from)} DEPTH #{depth}"
        direction.both? ? sql : "#{sql} DIRECTION #{direction.to_s.upcase}"
      end

      # Hash/Array option values are JSON-encoded so e.g. personalized
      # PageRank renders PERSONALIZATION {"alice":1.0} (parser-valid),
      # mirroring nodedb-ruby's render_algo_value.
      def self.algo(table : String, algo : String,
                    options : Hash(String, AlgoValue) = {} of String => AlgoValue) : String
        String.build do |s|
          s << "GRAPH ALGO " << Quoting.identifier(algo).upcase
          s << " ON " << Quoting.identifier(table)
          options.each do |key, value|
            s << ' ' << Quoting.identifier(key).upcase << ' ' << render_algo_value(value)
          end
        end
      end

      def self.delete_edge(in_collection : String, from : String, to : String, type : String) : String
        String.build do |s|
          s << "GRAPH DELETE EDGE IN " << Quoting.identifier(in_collection)
          s << " FROM " << Quoting.string(from) << " TO " << Quoting.string(to)
          s << " TYPE " << Quoting.string(type)
        end
      end

      def self.stats(collection : String? = nil, verbose : Bool = false, as_of : Int64? = nil) : String
        String.build do |s|
          s << "SHOW GRAPH STATS"
          s << ' ' << Quoting.identifier(collection) if collection
          s << " VERBOSE" if verbose
          s << " AS OF SYSTEM TIME " << as_of if as_of
        end
      end

      private def self.render_algo_value(value : Hash | Array) : String
        value.to_json
      end

      private def self.render_algo_value(value) : String
        value.to_s
      end
    end
  end
end
