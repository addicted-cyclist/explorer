# frozen_string_literal: true

require "test_helper"

# The Route Planner's persistence contracts on the Route model
# (technote.ROUTE-DRAW.md §9, §12): separate waypoint/POI collections, an
# editor state builder for reopening, and deep copies that carry the full
# planner state so a joined drawn ride stays editable in the joiner's
# library.
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
    @route.pois.create!(lat: 49.411, lon: 8.711, title: "Fountain", routing_waypoint: @waypoint_a)
  end

  test "planner_state carries profile, loop flag and the waypoint/POI collections" do
    state = @route.planner_state

    assert_equal "gravel", state[:profile]
    assert state[:loop]
    assert_equal 2, state[:waypoints].size
    assert_equal @waypoint_a.id, state[:waypoints].first[:id]
    assert_not state.key?(:shaping_points) # §12: hidden points are gone
    assert_equal 1, state[:pois].size
    assert_equal [ [ 8.71, 49.41, 100.0 ], [ 8.72, 49.42, 120.0 ] ], state[:segments].first
  end

  test "planner_state of an uploaded route seeds editor waypoints from the GPX track" do
    uploaded = @user.routes.create!(source: "upload", title: "GPX ride")
    uploaded.gpx_file.attach(
      io: File.open(Rails.root.join("test/fixtures/files/exploration.gpx")),
      filename: "exploration.gpx",
      content_type: "application/gpx+xml"
    )

    state = uploaded.planner_state

    # Short track (≈270 m): start + finish seeded, the whole track as their
    # segment — the editor opens ready to edit without any recalculation.
    assert_equal 2, state[:waypoints].size
    assert_nil state[:waypoints].first[:id]
    assert_equal [ 8.5417, 47.3769 ], [ state[:waypoints].first[:lon], state[:waypoints].first[:lat] ]
    assert_equal [ 8.5437, 47.3789 ], [ state[:waypoints].last[:lon], state[:waypoints].last[:lat] ]
    assert_not state.key?(:shaping_points)
    assert_empty state[:pois]
    assert_equal 1, state[:segments].size
    assert_equal [ 8.5417, 47.3769, 100.0 ], state[:segments].first.first
    assert_equal [ 8.5437, 47.3789, 120.0 ], state[:segments].first.last
  end

  test "planner_state splits a long uploaded track into locally-editable slices" do
    uploaded = @user.routes.create!(source: "upload", title: "Long ride")
    uploaded.gpx_file.attach(
      io: StringIO.new(linear_track_gpx(2_700, step_deg: 1e-4)),
      filename: "long.gpx",
      content_type: "application/gpx+xml"
    )

    state = uploaded.planner_state

    # ~30 km at ~11 m steps → four slices of ≤ 10 km, a seeded waypoint at
    # every cut. A drag then only ever recalculates its local slice.
    assert_equal 5, state[:waypoints].size
    assert_equal 4, state[:segments].size
    assert_equal [ 8.0, 47.0 ], [ state[:waypoints].first[:lon], state[:waypoints].first[:lat] ]
    assert_equal [ 8.0, 47.2699 ], [ state[:waypoints].last[:lon], state[:waypoints].last[:lat] ]
    # Every slice starts and ends exactly at its boundary waypoints — cuts
    # are track points shared by adjacent slices, so the union rebuilds the
    # ride byte-for-byte and the saver's endpoint check passes on save.
    state[:segments].each_with_index do |segment, index|
      assert_equal state[:waypoints][index][:lat], segment.first[1]
      assert_equal state[:waypoints][index][:lon], segment.first[0]
      assert_equal state[:waypoints][index + 1][:lat], segment.last[1]
      assert_equal state[:waypoints][index + 1][:lon], segment.last[0]
    end
    state[:segments].each do |segment|
      assert_operator Map::TrackGeometry.cumulative_distance_m(segment).last, :<=,
                      Route::PLANNER_SEED_SEGMENT_M + 20
    end
  end

  test "planner_state caps a dense uploaded track at the saver's segment limit" do
    uploaded = @user.routes.create!(source: "upload", title: "Dense recording")
    limit = Planner::RouteSaver::MAX_SEGMENT_POINTS
    # 25k points within ~5.5 km — under the split threshold, over the cap.
    uploaded.gpx_file.attach(
      io: StringIO.new(linear_track_gpx(limit + 5_000, step_deg: 2e-6)),
      filename: "dense.gpx",
      content_type: "application/gpx+xml"
    )

    state = uploaded.planner_state

    # The editor hands the same geometry back on save, so no shipped slice
    # may exceed the segment length the saver accepts (the resampler sits
    # just under the cap for this fixture's duplicate coordinates — the
    # bound is the contract, not the exact count).
    assert_equal 2, state[:waypoints].size
    assert_equal 1, state[:segments].size
    assert_operator state[:segments].first.size, :<=, limit
    assert_operator state[:segments].first.size, :>, limit - 100
    # The track ends survive the cap — they are the seeded start/finish RWs.
    assert_in_delta 47.0, state[:waypoints].first[:lat], 1e-9
    assert_in_delta 47.05, state[:waypoints].last[:lat], 1e-6
  end

  test "destroying the route removes both collections" do
    assert_difference -> { RoutingWaypoint.count } => -2,
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

  test "deep copy carries RWs, POIs and the generated GPX metadata" do
    rider = User.create!(valid_user_attributes(email: "joiner@example.com", username: "joiner"))

    copy = @route.deep_copy_for(rider)
    copy.save!

    assert_equal rider, copy.user
    assert_equal "drawn", copy.source
    assert_equal "gravel", copy.routing_profile
    assert_equal 2, copy.routing_waypoints.count
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

  private

  # A GPX with +count+ northward trackpoints (+step_deg+ apart) so the slice
  # and cap tests control both the track's length and its point density.
  def linear_track_gpx(count, step_deg:)
    body = Array.new(count) do |index|
      format('<trkpt lat="%.6f" lon="8.000000"><ele>10</ele></trkpt>', 47 + index * step_deg)
    end.join("\n")
    <<~GPX
      <?xml version="1.0" encoding="UTF-8"?>
      <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
        <trk><trkseg>
        #{body}
        </trkseg></trk>
      </gpx>
    GPX
  end
end
