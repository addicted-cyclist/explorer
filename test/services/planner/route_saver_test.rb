# frozen_string_literal: true

require "test_helper"

# Persistence for the Route Planner (technote.ROUTE-DRAW.md §6.1/§9): the
# editor state becomes a first-class Route — stats/bounds/map-geometry/GPX
# recomputed server-side, RW/SP/POI collections persisted separately, all in
# one transaction. The trust boundary (segment count + endpoint tolerance)
# is pinned here.
class Planner::RouteSaverTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(valid_user_attributes)
  end

  # A small valid two-waypoint route: RW 49.41,8.71 → RW 49.42,8.72 with a
  # two-point geometry whose endpoints sit exactly on the RWs.
  def valid_state(overrides = {})
    {
      "title" => "Test drawn route",
      "profile" => "road",
      "loop" => false,
      "waypoints" => [ { "lat" => 49.4100, "lon" => 8.7100 }, { "lat" => 49.4200, "lon" => 8.7200 } ],
      "shaping_points" => [],
      "pois" => [],
      "segments" => [ { "points" => [ [ 8.7100, 49.4100, 110.0 ], [ 8.7200, 49.4200, 130.0 ] ], "time_s" => 600 } ]
    }.deep_merge(overrides)
  end

  test "persists a drawn route as a first-class library member" do
    route = Planner::RouteSaver.call(user: @user, route: nil, state: valid_state)

    assert route.persisted?
    assert_equal "drawn", route.source
    assert_equal "road", route.routing_profile
    assert_equal "road", route.sport_type
    assert_equal "Test drawn route", route.title
    # Stats recomputed from the geometry, never taken from the client.
    assert_in_delta 1327.0, route.distance * 1000, 2.0
    assert_in_delta 20.0, route.elevation_gain, 0.1
    assert_equal 600, route.duration
    assert_equal 110.0, route.min_elevation
    assert_equal 130.0, route.max_elevation
    assert_equal [ 8.71, 49.41, 8.72, 49.42 ], route.bounds_array
    # §9: calculated geometry + generated GPX both persisted.
    assert_equal 1, route.planner_geometry["segments"].size
    assert_equal "road", route.planner_geometry["profile"]
    assert route.gpx_file.attached?
    assert_equal "application/gpx+xml", route.gpx_file.content_type
    # RW/SP/POI collections stay separate (§9).
    assert_equal 2, route.routing_waypoints.count
    assert_equal 0, route.shaping_points.count
    assert_equal [ 49.41, 8.71 ], route.routing_waypoints.first.coordinates
  end

  test "shaping points persist with their segment association and order" do
    state = valid_state(
      "shaping_points" => [
        { "segment_index" => 0, "position" => 0, "lat" => 49.4150, "lon" => 8.7150 }
      ]
    )

    route = Planner::RouteSaver.call(user: @user, route: nil, state: state)

    point = route.shaping_points.sole
    assert_equal 0, point.segment_index
    assert_equal 0, point.position
  end

  test "loop routes persist the closing segment" do
    state = valid_state(
      "loop" => true,
      "segments" => [
        { "points" => [ [ 8.7100, 49.4100, 110.0 ], [ 8.7200, 49.4200, 130.0 ] ], "time_s" => 600 },
        { "points" => [ [ 8.7200, 49.4200, 130.0 ], [ 8.7100, 49.4100, 110.0 ] ], "time_s" => 900 }
      ]
    )

    route = Planner::RouteSaver.call(user: @user, route: nil, state: state)

    assert route.planner_geometry["loop"]
    assert_equal 2, route.planner_geometry["segments"].size
    assert_equal 1500, route.duration
  end

  test "POIs persist with metadata, optional RW link and image" do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("png-bytes"), filename: "poi.png", content_type: "image/png"
    )
    state = valid_state(
      "pois" => [
        { "lat" => 49.4105, "lon" => 8.7105, "title" => "Viewpoint",
          "description" => "Regroup here", "external_url" => "https://example.com/view",
          "waypoint_index" => 0, "image_signed_id" => blob.signed_id }
      ]
    )

    route = Planner::RouteSaver.call(user: @user, route: nil, state: state)

    poi = route.pois.sole
    assert_equal "Viewpoint", poi.title
    assert_equal route.routing_waypoints.first.id, poi.routing_waypoint_id
    assert poi.image.attached?
  end

  test "segment count and endpoints are validated (the trust boundary)" do
    assert_raises(Planner::RouteSaver::ValidationError) do
      Planner::RouteSaver.call(user: @user, route: nil, state: valid_state("segments" => []))
    end
    # Endpoints within tolerance pass...
    state = valid_state(
      "segments" => [ { "points" => [ [ 8.7100, 49.4101, 110.0 ], [ 8.7200, 49.4200, 130.0 ] ] } ]
    )
    assert Planner::RouteSaver.call(user: @user, route: nil, state: state)
    # ...but a segment starting kilometres away does not.
    far = valid_state(
      "segments" => [ { "points" => [ [ 8.9000, 49.6000, 110.0 ], [ 8.7200, 49.4200, 130.0 ] ] } ]
    )
    error = assert_raises(Planner::RouteSaver::ValidationError) do
      Planner::RouteSaver.call(user: @user, route: nil, state: far)
    end
    assert_match /does not start at its waypoints/, error.errors.first
  end

  test "editing an existing route replaces collections wholesale" do
    route = Planner::RouteSaver.call(user: @user, route: nil, state: valid_state)
    old_waypoint_id = route.routing_waypoints.first.id

    edited = Planner::RouteSaver.call(user: @user, route: route, state: valid_state(
      "title" => "Edited drawn route",
      "waypoints" => [ { "lat" => 49.4100, "lon" => 8.7100 }, { "lat" => 49.4300, "lon" => 8.7300 } ],
      "segments" => [ { "points" => [ [ 8.7100, 49.4100, 110.0 ], [ 8.7300, 49.4300, 150.0 ] ] } ]
    ))

    assert_equal route.id, edited.id
    assert_equal "Edited drawn route", edited.title
    assert_equal 2, edited.routing_waypoints.count
    assert_not_equal old_waypoint_id, edited.routing_waypoints.first.id
  end

  test "garbage never crashes the saver — it becomes validation errors" do
    assert_raises(Planner::RouteSaver::ValidationError) do
      Planner::RouteSaver.call(user: @user, route: nil, state: valid_state("waypoints" => [ { "lat" => 49.41, "lon" => 8.71 } ]))
    end
    assert_raises(Planner::RouteSaver::ValidationError) do
      Planner::RouteSaver.call(user: @user, route: nil, state: valid_state("profile" => "skate"))
    end
    assert_raises(Planner::RouteSaver::ValidationError) do
      Planner::RouteSaver.call(
        user: @user, route: nil,
        state: valid_state("shaping_points" => [ { "segment_index" => 9, "position" => 0, "lat" => 49.41, "lon" => 8.71 } ])
      )
    end
  end

  test "javascript: URLs are dropped, never stored beside a clickable link" do
    state = valid_state(
      "pois" => [ { "lat" => 49.4105, "lon" => 8.7105, "title" => "Sneaky",
                    "external_url" => "javascript:alert(1)" } ]
    )

    route = Planner::RouteSaver.call(user: @user, route: nil, state: state)

    assert_nil route.pois.first.external_url
  end
end
