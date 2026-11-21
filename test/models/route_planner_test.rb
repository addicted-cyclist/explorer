# frozen_string_literal: true

require "test_helper"

# The Route Planner's persistence contracts on the Route model
# (technote.ROUTE-DRAW.md §9): three separate collections, an editor state
# builder for reopening, and deep copies that carry the full planner state
# so a joined drawn ride stays editable in the joiner's library.
class RoutePlannerTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(valid_user_attributes)
    @route = @user.routes.create!(
      source: "drawn", title: "Drafthouse Loop", routing_profile: "gravel",
      planner_geometry: {
        "profile" => "gravel", "loop" => true,
        "segments" => [ { "points" => [ [ 8.71, 49.41, 100.0 ], [ 8.72, 49.42, 120.0 ] ] } ]
      }
    )
    @waypoint_a = @route.routing_waypoints.create!(position: 0, lat: 49.41, lon: 8.71)
    @waypoint_b = @route.routing_waypoints.create!(position: 1, lat: 49.42, lon: 8.72)
    @route.shaping_points.create!(segment_index: 0, position: 0, lat: 49.415, lon: 8.715)
    @route.pois.create!(lat: 49.411, lon: 8.711, title: "Fountain", routing_waypoint: @waypoint_a)
  end

  test "planner_state carries profile, loop flag and the three collections" do
    state = @route.planner_state

    assert_equal "gravel", state[:profile]
    assert state[:loop]
    assert_equal 2, state[:waypoints].size
    assert_equal @waypoint_a.id, state[:waypoints].first[:id]
    assert_equal 1, state[:shaping_points].size
    assert_equal 0, state[:shaping_points].first[:segment_index]
    assert_equal 1, state[:pois].size
    assert_equal [ [ 8.71, 49.41, 100.0 ], [ 8.72, 49.42, 120.0 ] ], state[:segments].first
  end

  test "destroying the route removes all three collections" do
    assert_difference -> { RoutingWaypoint.count } => -2,
                     -> { ShapingPoint.count } => -1,
                     -> { RoutePoi.count } => -1 do
      @route.destroy
    end
  end

  test "deleting a routing waypoint nullifies its POI link, never the POI" do
    @waypoint_a.destroy!

    poi = @route.pois.reload.first
    assert_not_nil poi
    assert_nil poi.routing_waypoint_id
    assert_in_delta 49.411, poi.lat, 0.000001
  end

  test "deep copy carries RWs, SPs, POIs and the generated GPX metadata" do
    rider = User.create!(valid_user_attributes(email: "joiner@example.com", username: "joiner"))

    copy = @route.deep_copy_for(rider)
    copy.save!

    assert_equal rider, copy.user
    assert_equal "drawn", copy.source
    assert_equal "gravel", copy.routing_profile
    assert_equal 2, copy.routing_waypoints.count
    assert_equal 1, copy.shaping_points.count
    assert_equal 1, copy.pois.count
    assert_equal @route.planner_geometry, copy.planner_geometry
    # The copy's POI links to the COPY's waypoint, not the original's.
    assert_equal copy.routing_waypoints.first.id, copy.pois.first.routing_waypoint_id
  end

  test "deep copy of an uploaded route stays an upload" do
    uploaded = @user.routes.create!(source: "upload", title: "GPX ride")

    copy = uploaded.deep_copy_for(@user)

    assert_equal "upload", copy.source
  end
end
