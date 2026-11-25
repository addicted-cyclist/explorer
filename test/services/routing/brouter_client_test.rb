# frozen_string_literal: true

require "test_helper"

# The Routing Engine Adapter (technote.ROUTE-DRAW.md §10.4): converts control
# points into BRouter requests, parses the GeoJSON responses, caches
# identical requests and translates every failure mode into the two
# user-safe errors. The HTTP layer is stubbed — these tests pin the contract
# with BRouter, not the network.
class Routing::BrouterClientTest < ActiveSupport::TestCase
  GEOJSON = <<~JSON
    {
      "type": "FeatureCollection",
      "features": [{
        "type": "Feature",
        "properties": {
          "creator": "BRouter-1.7.0",
          "name": "brouter",
          "track-length": "24680",
          "filtered ascend": "321",
          "plain-ascend": "300",
          "total-time": "4800",
          "total-energy": "900000",
          "cost": "24700",
          "messages": []
        },
        "geometry": {
          "type": "LineString",
          "coordinates": [[8.7100, 49.4100, 110.5], [8.7120, 49.4120, 122.0], [8.7140, 49.4140, 130.0]]
        }
      }]
    }
  JSON

  POINTS = [ [ 49.4100, 8.7100 ], [ 49.4140, 8.7140 ] ]

  def setup
    # The suite runs on :null_store — give the caching tests a real one.
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  def teardown
    Rails.cache = @original_cache
  end

  def with_http(body_or_lambda)
    with_brouter_engine(body_or_lambda) do
      yield
    end
  end

  test "calculates a segment into the app's standard shape" do
    with_http(GEOJSON) do
      segment = Routing::BrouterClient.calculate_segment(points: POINTS, profile: "road")

      assert_equal 3, segment.coordinates.size
      assert_equal [ 8.7100, 49.4100, 110.5 ], segment.coordinates.first
      assert_in_delta 24_680, segment.distance_m, 0.1
      assert_in_delta 321, segment.ascend_m, 0.1
      assert_in_delta 4800, segment.time_s, 0.1
    end
  end

  test "handles 2D responses (no elevation data installed)" do
    body = GEOJSON.gsub(/, (110\.5|122\.0|130\.0)\]/, "]")
    with_http(body) do
      segment = Routing::BrouterClient.calculate_segment(points: POINTS, profile: "gravel")

      assert_nil segment.coordinates.first[2]
    end
  end

  test "caches identical requests (same rounded coordinates + profile)" do
    calls = 0
    client = ->(_url) { calls += 1; GEOJSON }
    with_http(client) do
      2.times { Routing::BrouterClient.calculate_segment(points: POINTS, profile: "road") }
    end
    assert_equal 1, calls, "identical requests must be served from the cache (§10.6)"
  end

  test "different profiles do not share cache entries" do
    calls = 0
    client = ->(_url) { calls += 1; GEOJSON }
    with_http(client) do
      Routing::BrouterClient.calculate_segment(points: POINTS, profile: "road")
      Routing::BrouterClient.calculate_segment(points: POINTS, profile: "mtb")
    end
    assert_equal 2, calls
  end

  test "a plain-text failure body becomes RequestFailed with a usable message" do
    with_http("datafile not found") do
      error = assert_raises(Routing::BrouterClient::RequestFailed) do
        Routing::BrouterClient.calculate_segment(points: POINTS, profile: "road")
      end
      assert_match /not installed yet/, error.message
    end
  end

  test "an unroutable segment becomes RequestFailed, never a fake route" do
    with_http("Datafile invalid or connection disturbed") do
      error = assert_raises(Routing::BrouterClient::RequestFailed) do
        Routing::BrouterClient.calculate_segment(points: POINTS, profile: "road")
      end
      assert_match /No route could be calculated/, error.message
    end
  end

  test "point validation rejects garbage before any HTTP happens" do
    assert_raises(ArgumentError) { Routing::BrouterClient.calculate_segment(points: [ [ 49.4 ] ], profile: "road") }
    assert_raises(ArgumentError) { Routing::BrouterClient.calculate_segment(points: [], profile: "road") }
    assert_raises(ArgumentError) do
      Routing::BrouterClient.calculate_segment(points: [ [ 49.4100, 8.7100 ], [ 95.0, 8.7140 ] ], profile: "road")
    end
    assert_raises(ArgumentError) do
      Routing::BrouterClient.calculate_segment(points: POINTS, profile: "bogus")
    end
  end
end
