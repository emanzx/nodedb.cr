require "../spec_helper"

describe NodeDB::SQL::Spatial do
  it "builds within_distance with lon-first ST_Point" do
    NodeDB::SQL::Spatial.within_distance(column: "geom", lat: 3.15, lon: 101.7, meters: 500.0)
      .should eq("ST_DWithin(geom, ST_Point(101.7, 3.15), 500.0)")
  end

  it "builds distance_expr" do
    NodeDB::SQL::Spatial.distance_expr(column: "geom", lat: 3.15, lon: 101.7)
      .should eq("ST_Distance(geom, ST_Point(101.7, 3.15)) AS distance")
  end

  it "builds bbox_filter" do
    NodeDB::SQL::Spatial.bbox_filter(column: "geom", min_lon: 101.0, min_lat: 3.0, max_lon: 102.0, max_lat: 4.0)
      .should eq("geom && ST_MakeEnvelope(101.0, 3.0, 102.0, 4.0, 4326)")
  end
end
