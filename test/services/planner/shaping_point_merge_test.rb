# frozen_string_literal: true

require "test_helper"

# Pins the pure transform behind the one-shot migration
# (db/migrate/20261125090000_merge_shaping_points_into_waypoints.rb) that
# turns persisted Shaping Points into plotted Routing Waypoints (§12). The
# migration class is loaded directly and only its data shaping is exercised
# here — no DB, no running the migration itself.
class Planner::ShapingPointMergeTest < ActiveSupport::TestCase
  TESTS = Rails.root.join("db/migrate/20261125090000_merge_shaping_points_into_waypoints.rb")
  load TESTS

  test "merged_waypoints interleaves each shaping point after its segment's first waypoint" do
    waypoints = [
      { id: 1, lat: 49.40, lon: 8.70 },
      { id: 2, lat: 49.42, lon: 8.72 },
      { id: 3, lat: 49.44, lon: 8.74 }
    ]
    shaping = [
      { segment_index: 0, position: 0, lat: 49.41, lon: 8.71 },
      { segment_index: 1, position: 0, lat: 49.43, lon: 8.73 }
    ]

    merged = MergeShapingPointsIntoWaypoints.merged_waypoints(waypoints, shaping)

    assert_equal [
      [ 49.40, 8.70 ], [ 49.41, 8.71 ], # segment 0's SP right after RW 0
      [ 49.42, 8.72 ], [ 49.43, 8.73 ], # segment 1's SP right after RW 1
      [ 49.44, 8.74 ]
    ], merged
  end

  test "merged_waypoints places a loop closing segment's shaping points last" do
    waypoints = [ { id: 1, lat: 49.40, lon: 8.70 }, { id: 2, lat: 49.42, lon: 8.72 } ]
    # A two-waypoint loop has segments 0 (A→B) and 1 (B→A, the closing one).
    shaping = [ { segment_index: 1, position: 0, lat: 49.41, lon: 8.71 } ]

    merged = MergeShapingPointsIntoWaypoints.merged_waypoints(waypoints, shaping)

    assert_equal [ [ 49.40, 8.70 ], [ 49.42, 8.72 ], [ 49.41, 8.71 ] ], merged
  end

  test "split_segments cuts a segment at the vertices nearest its shaping points" do
    # A straight eastward line with vertices at every 0.01° of longitude.
    points = Array.new(5) { |index| [ 8.70 + index * 0.01, 49.40, 100.0 + index ] }
    segments = [ { points: points, time_s: 600.0 } ]
    # An SP exactly on the second vertex, plus one clearly nearer vertex 3.
    shaping = [
      { segment_index: 0, position: 0, lat: 49.40, lon: 8.71 },
      { segment_index: 0, position: 1, lat: 49.40, lon: 8.734 }
    ]

    pieces = MergeShapingPointsIntoWaypoints.split_segments(segments, shaping)

    # Two SPs → three pieces; adjacent pieces share the boundary vertex, so
    # the union is the original line. (Deltas: the vertices are built with
    # float steps, so exact equality is not meaningful here.)
    assert_equal 3, pieces.size
    assert_in_delta 8.70, pieces[0][:points].first[0], 1e-9
    assert_in_delta 8.71, pieces[0][:points].last[0], 1e-9
    assert_in_delta 8.71, pieces[1][:points].first[0], 1e-9
    assert_in_delta 8.73, pieces[1][:points].last[0], 1e-9
    assert_in_delta 8.73, pieces[2][:points].first[0], 1e-9
    assert_in_delta 8.74, pieces[2][:points].last[0], 1e-9
    # Engine time stays on the first piece only — never double-counted.
    assert_equal 600.0, pieces[0][:time_s]
    assert_nil pieces[1][:time_s]
    assert_nil pieces[2][:time_s]
  end

  test "split_segments leaves SP-free segments untouched" do
    segments = [ { points: [ [ 8.70, 49.40, 100.0 ], [ 8.72, 49.42, 120.0 ] ], time_s: 600.0 } ]

    pieces = MergeShapingPointsIntoWaypoints.split_segments(segments, [])

    assert_equal segments, pieces
  end

  test "split_segments skips degenerate cuts (SP snapped to a segment end)" do
    points = [ [ 8.70, 49.40, 100.0 ], [ 8.71, 49.40, 101.0 ], [ 8.72, 49.40, 102.0 ] ]
    segments = [ { points: points, time_s: nil } ]
    # Both SPs sit on the segment's end vertices — no interior cut exists.
    shaping = [
      { segment_index: 0, position: 0, lat: 49.40, lon: 8.70 },
      { segment_index: 0, position: 1, lat: 49.40, lon: 8.72 }
    ]

    pieces = MergeShapingPointsIntoWaypoints.split_segments(segments, shaping)

    assert_equal segments, pieces
  end
end
