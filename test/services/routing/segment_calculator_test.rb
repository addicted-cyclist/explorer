# frozen_string_literal: true

require "test_helper"

# Request coordination for the planner's segment endpoint
# (technote.ROUTE-DRAW.md §10.2): normalizes controller params into control
# points and the adapter's Segment into the client's JSON payload. The
# engine call itself is stubbed — the seam, not the network, is under test.
class Routing::SegmentCalculatorTest < ActiveSupport::TestCase
  GEOJSON = <<~JSON
    {
      "type": "FeatureCollection",
      "features": [{
        "type": "Feature",
        "properties": { "track-length": "2468.0", "filtered ascend": "19.5", "total-time": "480" },
        "geometry": {
          "type": "LineString",
          "coordinates": [[8.7100, 49.4100, 110.5], [8.7140, 49.4140, 130.0]]
        }
      }]
    }
  JSON

  test "returns the client payload shape" do
    with_brouter_engine(GEOJSON) do
      result = Routing::SegmentCalculator.call(
        points: [ [ 49.4100, 8.7100 ], [ 49.4140, 8.7140 ] ],
        profile: "road"
      )

      assert_equal [ [ 8.71, 49.41, 110.5 ], [ 8.714, 49.414, 130.0 ] ], result[:coordinates]
      assert_equal 2468.0, result[:distance_m]
      assert_equal 19.5, result[:ascend_m]
      assert_equal 480, result[:time_s]
      assert_equal "road", result[:profile]
    end
  end

  test "numeric strings from params are coerced" do
    with_brouter_engine(GEOJSON) do
      result = Routing::SegmentCalculator.call(
        points: [ [ "49.4100", "8.7100" ], [ 49.4140, 8.7140 ] ],
        profile: "mtb"
      )
      assert_equal 49.41, result[:coordinates].first[1]
      assert_equal "mtb", result[:profile]
    end
  end

  test "garbage points and unknown profiles raise ArgumentError" do
    assert_raises(ArgumentError) do
      Routing::SegmentCalculator.call(points: [ [ 49.4100, 8.7100 ], [ "north", 8.7 ] ], profile: "road")
    end
    assert_raises(ArgumentError) do
      Routing::SegmentCalculator.call(points: [ [ 49.4100, 8.7100 ] ], profile: "road")
    end
    assert_raises(ArgumentError) do
      Routing::SegmentCalculator.call(points: [ [ 49.4100, 8.7100 ], [ 49.4140, 8.7140 ] ], profile: "bmx")
    end
  end
end
