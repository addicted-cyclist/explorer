# frozen_string_literal: true

module Routing
  # Request coordination for the planner's segment endpoint
  # (technote.ROUTE-DRAW.md §10.2 "Request coordination / Response
  # processing"): normalizes the controller's raw params into the adapter's
  # [lat, lon] control-point list and the adapter's Segment back into the
  # JSON the planner client renders. Everything engine-specific stays inside
  # Routing::BrouterClient; this class is the thin, testable seam between
  # HTTP and the engine.
  class SegmentCalculator
    class << self
      # +points+ are [lat, lon] pairs in travel order (the segment's plotted
      # waypoints — two since §12). Returns { coordinates: [[lon, lat, ele], ...], distance_m:, ascend_m:,
      # time_s:, profile: } — the exact payload the client merges into its
      # segment list.
      def call(points:, profile:)
        raise ArgumentError, "unknown routing profile" unless Route::ROUTING_PROFILES.include?(profile)

        control_points = points.map { |lat, lon| [ Float(lat), Float(lon) ] }
        segment = BrouterClient.calculate_segment(points: control_points, profile: profile)
        {
          coordinates: segment.coordinates,
          distance_m: segment.distance_m.round(1),
          ascend_m: segment.ascend_m.round(1),
          time_s: segment.time_s.round,
          profile: profile
        }
      rescue ArgumentError, TypeError
        raise ArgumentError, "points must be [lat, lon] pairs with numeric coordinates"
      end
    end
  end
end
