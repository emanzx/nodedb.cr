module NodeDB
  module SQL
    # Spatial expression builders (ST_* functions). ST_Point takes lon, lat.
    module Spatial
      def self.within_distance(column : String, lat : Float64, lon : Float64, meters : Float64) : String
        "ST_DWithin(#{Quoting.identifier(column)}, ST_Point(#{lon}, #{lat}), #{meters})"
      end

      def self.distance_expr(column : String, lat : Float64, lon : Float64,
                             as_alias : String = "distance") : String
        "ST_Distance(#{Quoting.identifier(column)}, ST_Point(#{lon}, #{lat})) AS #{Quoting.identifier(as_alias)}"
      end

      def self.bbox_filter(column : String, min_lon : Float64, min_lat : Float64,
                           max_lon : Float64, max_lat : Float64) : String
        "#{Quoting.identifier(column)} && ST_MakeEnvelope(#{min_lon}, #{min_lat}, #{max_lon}, #{max_lat}, 4326)"
      end
    end
  end
end
