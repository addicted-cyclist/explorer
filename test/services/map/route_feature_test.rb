# frozen_string_literal: true

require "test_helper"

# Unit tests for the Map page's GeoJSON builder (technote.MYMAP-FEATURE.md
# §5): geometry plays back the stored map geometry (derived at parse time),
# properties stay compact and are rebuilt from the live columns on every
# build — detail-page edits surface immediately, and rows the backfill has
# not reached yet self-heal on first build.
class Map::RouteFeatureTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(valid_user_attributes)
    @route = @user.routes.create!(source: "upload", title: "Alpine loop", sport_type: "Road Cycling",
                                  distance: 27.7, elevation_gain: 485.0, duration: 5040)
    @route.gpx_file.attach(gpx_fixture_upload("exploration.gpx"))
    store_derived_map_data(@route)
  end

  test "builds a Feature with LineString geometry from the stored map geometry" do
    feature = Map::RouteFeature.build(@route, own: true)

    assert_equal "Feature", feature["type"]
    assert_equal @route.id, feature["id"]
    assert_equal "LineString", feature["geometry"]["type"]
    assert_equal [ [ 8.5417, 47.3769 ], [ 8.5427, 47.3779 ], [ 8.5437, 47.3789 ] ],
                 feature["geometry"]["coordinates"]
  end

  test "properties carry the compact metadata set the client needs" do
    properties = Map::RouteFeature.build(@route, own: true)["properties"]

    assert_equal @route.id, properties["id"]
    assert_equal "Alpine loop", properties["title"]
    assert_equal 27.7, properties["distance"]
    assert_equal 485.0, properties["elevation_gain"]
    assert_equal 5040, properties["duration"]
    assert_in_delta 19.8, properties["avg_speed_kmh"], 0.1
    assert_equal true, properties["own"]
    assert_equal [ 8.5417, 47.3769, 8.5437, 47.3789 ], properties["bounds"]
    assert_equal Rails.application.routes.url_helpers.route_path(@route.id), properties["url"]
    assert_equal Rails.application.routes.url_helpers.download_route_path(@route.id), properties["download_url"]
  end

  test "build derives an elevation profile with monotonic distances" do
    profile = Map::RouteFeature.build(@route, own: true)["properties"]["elevation_profile"]

    assert_equal [ [ 0, 100 ], [ 0, 150 ], [ 0, 120 ] ].length, profile.length
    assert_operator profile.first[1], :>, 90
    assert_equal 100, profile.first[1]
    assert_equal 120, profile.last[1]
    # Distances never decrease along the track.
    profile.each_cons(2) { |(d1, _), (d2, _)| assert_operator d2, :>=, d1 }
  end

  test "own and public flags are merged per build, never shared between collections" do
    Map::RouteFeature.build(@route, own: true)
    feature = Map::RouteFeature.build(@route, own: false)

    assert_equal false, feature["properties"]["own"]
  end

  test "collection wraps features in a FeatureCollection" do
    payload = Map::RouteFeature.collection([ @route ], own: true)

    assert_equal "FeatureCollection", payload["type"]
    assert_equal 1, payload["features"].size
    assert_equal true, payload["features"].first["properties"]["own"]
  end

  test "collection marks own routes public only when scheduled on a public calendar" do
    @user.update!(calendar_public: true)
    @user.calendar_entries.create!(route: @route, scheduled_on: Date.current + 2,
                                   start_time: "08:00", end_time: "09:00")
    public_ids = CalendarEntry.where(user: @user).distinct.pluck(:route_id)

    payload = Map::RouteFeature.collection([ @route ], own: true, public_ids: public_ids)
    assert_equal true, payload["features"].first["properties"]["public"]
  end

  test "routes without a gpx still build as null-geometry features" do
    bare = @user.routes.create!(source: "upload", title: "Never parsed")

    feature = Map::RouteFeature.build(bare, own: true)
    assert_nil feature["geometry"]
    assert_nil feature["properties"]["bounds"]
    assert_nil feature["properties"]["elevation_profile"]
  end

  test "a gpx-backed route with no stored geometry derives and persists it once" do
    @route.update!(map_geometry: nil)

    feature = Map::RouteFeature.build(@route.reload, own: true)

    assert_equal "LineString", feature["geometry"]["type"]
    assert_equal [ [ 8.5417, 47.3769 ], [ 8.5427, 47.3779 ], [ 8.5437, 47.3789 ] ],
                 feature["geometry"]["coordinates"]
    # Self-heal: the derivation lands in the column, so no later request
    # ever re-parses the blob.
    assert @route.reload.map_geometry.present?
  end

  test "an unreadable gpx degrades to a null-geometry feature" do
    @route.update!(map_geometry: nil)
    @route.gpx_file.attach(gpx_fixture_upload("broken.gpx", content: "<gpx><trk><trkseg>"))

    feature = Map::RouteFeature.build(@route, own: true)

    assert_nil feature["geometry"]
    assert_equal "Alpine loop", feature["properties"]["title"]
  end

  test "detail-page edits surface without any cache clearing" do
    Map::RouteFeature.build(@route, own: true)

    @route.update!(title: "Renamed ridge loop", tier: "Hard")

    properties = Map::RouteFeature.build(@route, own: true)["properties"]
    assert_equal "Renamed ridge loop", properties["title"]
    assert_equal "Hard", properties["tier"]
  end

  private

  # The derived data a real upload flow writes at parse time (bounds +
  # stored geometry) — the same calls Route#parse_gpx! makes.
  def store_derived_map_data(route)
    points = route.track_coordinates
    route.update!(Route.map_bounds_from(points).merge(map_geometry: Map::TrackGeometry.build(points)))
  end
end
