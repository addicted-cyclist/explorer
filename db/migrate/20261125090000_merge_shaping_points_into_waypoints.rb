# frozen_string_literal: true

# §12 of technote.ROUTE-DRAW.md removed Shaping Points: a drawn route is now
# a pure sequence of plotted Routing Waypoints, so the hidden drag-created
# constraints must not survive in any form — neither in code nor as data.
#
# This one-shot migration converts every persisted Shaping Point into a
# Routing Waypoint at its place in the sequence (an SP on segment i sits
# right after the i-th RW) and splits the stored planner_geometry at the
# same points (nearest polyline vertex), so a reopened route keeps its exact
# shape and the waypoint/segment counts agree without a full recalculation.
#
# The transform itself is pure data shaping (merged_waypoints /
# split_segments) and unit-tested; this class only wires it to the tables.
#
# The conversion is deliberately one-way: +down+ recreates the empty table
# so the schema stays loadable, but former SPs are indistinguishable from
# user-placed RWs afterwards and cannot be restored.
class MergeShapingPointsIntoWaypoints < ActiveRecord::Migration[7.2]
  # Positions are renumbered 0..m-1 in one pass; shifting the existing rows
  # out of the way first keeps the (route_id, position) unique index happy.
  POSITION_SHIFT = 1_000_000

  def up
    route_ids = select_all("SELECT DISTINCT route_id FROM shaping_points").rows.flatten

    route_ids.each do |route_id|
      merge_route(route_id)
    end

    drop_table :shaping_points
  end

  def down
    create_table :shaping_points do |t|
      t.references :route, null: false, foreign_key: true
      t.integer :segment_index, null: false
      t.integer :position, null: false
      t.float :lat, null: false
      t.float :lon, null: false

      t.timestamps
    end
    add_index :shaping_points, %i[route_id segment_index position],
              name: "index_shaping_points_on_route_segment_position"
  end

  # ---- pure transform (unit-tested, no DB access) -------------------------

  class << self
    # Interleave [lat, lon] waypoints with shaping points: an SP recorded on
    # segment i belongs right after the i-th waypoint (the closing segment of
    # a loop is the last index, so its SPs land at the very end). Returns the
    # merged [lat, lon] sequence in final order.
    def merged_waypoints(waypoints, shaping_points)
      by_segment = Hash.new { |hash, key| hash[key] = [] }
      shaping_points.sort_by { |point| [ point[:segment_index], point[:position] ] }.each do |point|
        by_segment[point[:segment_index]] << [ point[:lat], point[:lon] ]
      end

      merged = []
      waypoints.each_with_index do |waypoint, index|
        merged << [ waypoint[:lat], waypoint[:lon] ]
        merged.concat(by_segment[index])
      end
      merged
    end

    # Split every SP-bearing segment at the polyline vertex nearest to each
    # of its shaping points (adjacent pieces share the boundary vertex, so
    # the union rebuilds the line exactly — the same convention the editor's
    # seeded slices use). Segments without SPs pass through untouched. A
    # boundary that degenerates (SP snapped to a segment's end vertex) is
    # skipped; the reopened route simply recalculates that piece.
    def split_segments(segments, shaping_points)
      by_segment = Hash.new { |hash, key| hash[key] = [] }
      shaping_points.sort_by { |point| [ point[:segment_index], point[:position] ] }.each do |point|
        by_segment[point[:segment_index]] << [ point[:lat], point[:lon] ]
      end

      segments.flat_map.with_index do |segment, index|
        points = segment[:points]
        cuts = cut_indexes(points, by_segment[index])
        next [ segment ] if cuts.empty?

        bounds = [ 0 ] + cuts + [ points.size - 1 ]
        bounds.each_cons(2).with_index.map do |(from, to), piece|
          # Only the first piece carries the engine time — duplicating it
          # would double-count the span on any consumer that sums the series.
          { points: points[from..to], time_s: piece.zero? ? segment[:time_s] : nil }
        end
      end
    end

    private

    def cut_indexes(points, sps)
      return [] if !points.is_a?(Array) || points.size < 3 || sps.nil? || sps.empty?

      sps.filter_map do |lat, lon|
        vertex = nearest_vertex(points, lat, lon)
        vertex unless vertex.zero? || vertex == points.size - 1
      end.uniq.sort
    end

    def nearest_vertex(points, lat, lon)
      best = 0
      best_distance = Float::INFINITY
      points.each_with_index do |(point_lon, point_lat, *_ele), index|
        distance = Map::TrackGeometry.haversine_m([ lon, lat ], [ point_lon, point_lat ])
        if distance < best_distance
          best_distance = distance
          best = index
        end
      end
      best
    end
  end

  # ---- DB wiring -----------------------------------------------------------

  def merge_route(route_id)
    waypoint_rows = select_all(<<~SQL.squish).to_a
      SELECT id, lat, lon FROM routing_waypoints
      WHERE route_id = #{route_id} ORDER BY position
    SQL
    shaping_rows = select_all(<<~SQL.squish).to_a
      SELECT segment_index, position, lat, lon FROM shaping_points
      WHERE route_id = #{route_id} ORDER BY segment_index, position
    SQL
    return if waypoint_rows.empty?

    waypoints = waypoint_rows.map do |row|
      { id: row["id"].to_i, lat: row["lat"].to_f, lon: row["lon"].to_f }
    end
    shaping = shaping_rows.map do |row|
      { segment_index: row["segment_index"].to_i, position: row["position"].to_i,
        lat: row["lat"].to_f, lon: row["lon"].to_f }
    end
    # The saver only ever persisted SPs inside the real segment range; a
    # stray index (corrupt data) is dropped rather than turned into a
    # geometry phantom — the exact failure §12 removes.
    valid_range = 0..(waypoints.size - 1)
    shaping.select! { |point| valid_range.cover?(point[:segment_index]) }

    # Clear the low position range, then walk the merged sequence: existing
    # rows keep their ids and take their final position; former SPs become
    # new waypoint rows.
    execute("UPDATE routing_waypoints SET position = position + #{POSITION_SHIFT} WHERE route_id = #{route_id}")
    self.class.merged_waypoints(waypoints, shaping).each_with_index do |(lat, lon), position|
      waypoint = waypoints.find { |candidate| candidate[:id] && candidate[:lat] == lat && candidate[:lon] == lon }
      if waypoint
        execute("UPDATE routing_waypoints SET position = #{position} WHERE id = #{waypoint[:id]}")
        waypoint[:id] = nil # each row positions exactly once
      else
        insert_waypoint(route_id, position, lat, lon)
      end
    end

    split_geometry(route_id, shaping)
  end

  def insert_waypoint(route_id, position, lat, lon)
    execute(<<~SQL.squish)
      INSERT INTO routing_waypoints (route_id, position, lat, lon, created_at, updated_at)
      VALUES (#{route_id}, #{position}, #{lat}, #{lon}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def split_geometry(route_id, shaping)
    raw = select_value("SELECT planner_geometry FROM routes WHERE id = #{route_id}")
    geometry = raw.is_a?(Hash) ? raw : (raw.present? ? JSON.parse(raw) : nil)
    return unless geometry.is_a?(Hash)

    stored = Array(geometry["segments"]).filter_map do |segment|
      next unless segment.is_a?(Hash) && segment["points"].is_a?(Array)

      { points: segment["points"], time_s: segment["time_s"] }
    end
    return if stored.empty?

    merged_segments = self.class.split_segments(stored, shaping)
    return if merged_segments == stored # nothing split — leave the row alone

    geometry["segments"] = merged_segments.map do |segment|
      { "points" => segment[:points], "time_s" => segment[:time_s] }
    end
    execute("UPDATE routes SET planner_geometry = #{quote(geometry.to_json)}::jsonb WHERE id = #{route_id}")
  end
end
