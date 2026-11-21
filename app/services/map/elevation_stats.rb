# frozen_string_literal: true

module Map
  # Elevation-series math shared by every route-stat writer: Route#parse_gpx!
  # (GPX uploads) and Planner::RouteSaver (drawn routes) must agree on what a
  # metre of climbing is, or the same ride would show different stats
  # depending on how it entered the library.
  #
  # Raw GPS altitude readings jitter by several meters between trackpoints;
  # feeding that noise to a gain/loss sum counts every wiggle as real
  # climb/descent and wildly inflates the stats. A centered moving average
  # (window ELEVATION_SMOOTHING_WINDOW) strips the jitter before the delta
  # sums; the window shrinks at the track ends (mean of the available
  # neighbours), so the result always has the same length as the input.
  # Series shorter than three points have no meaningful jitter to smooth and
  # are returned unchanged.
  module ElevationStats
    ELEVATION_SMOOTHING_WINDOW = 5

    class << self
      def smooth(elevations)
        return elevations if elevations.nil? || elevations.size < 3

        half = ELEVATION_SMOOTHING_WINDOW / 2
        elevations.each_index.map do |i|
          window = elevations[[ i - half, 0 ].max..[ i + half, elevations.size - 1 ].min]
          window.sum.to_f / window.size
        end
      end

      def gain(elevations)
        deltas(elevations) { |a, b| b > a ? b - a : 0.0 }
      end

      def loss(elevations)
        deltas(elevations) { |a, b| a > b ? a - b : 0.0 }
      end

      # Full stat set from [lon, lat, ele] triplets (ele may be nil): the
      # smoothed gain/loss plus min/max of the RAW readings. { gain:, loss:,
      # min:, max: } — nil values when no point carries an elevation.
      def stats(points)
        elevations = points.filter_map { |point| point[2] }
        return { gain: nil, loss: nil, min: nil, max: nil } if elevations.empty?

        smoothed = smooth(elevations)
        { gain: gain(smoothed), loss: loss(smoothed),
          min: elevations.min, max: elevations.max }
      end

      private

      def deltas(elevations)
        return 0.0 if elevations.nil?

        elevations.each_cons(2).sum do |a, b|
          yield a, b
        end
      end
    end
  end
end
