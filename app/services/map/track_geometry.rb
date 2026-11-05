# frozen_string_literal: true

module Map
  # Derives the stored per-route map geometry from a track's full-resolution
  # [lon, lat, ele] triplets (technote.MYMAP-FEATURE.md §5): a distance-even
  # resampled LineString for drawing and the compact elevation profile for
  # the popup chart. The result is write-once presentation data — it lives in
  # routes.map_geometry (written by Route#parse_gpx! at upload time and by the
  # map-geometry backfill) — and no route stat ever reads it back: distance,
  # elevation gain/loss and min/max are computed from the full series in
  # Route#parse_gpx! and stored in their own columns. Sampling error is
  # confined to the illustrative chart, as documented there.
  class TrackGeometry
    # Line cap: MapLibre renders these fine and the payload stays ~10KB.
    MAX_POINTS = 400
    # Chart resolution: more buckets than the popup SVG can usefully show.
    PROFILE_BUCKETS = 120

    EARTH_RADIUS_M = 6_371_000.0

    class << self
      # { "coordinates" => [[lon, lat], ...], "profile" => [[m, ele], ...] }
      # from +points+ ([lon, lat, ele] triplets). Both values are nil when the
      # track is too short to draw — the hash itself always returns, so a
      # persisted geometry only ever means "derivation was attempted", and a
      # nil column means "not derived yet".
      def build(points)
        sampled = downsample(points)
        {
          "coordinates" => line_coordinates(sampled),
          "profile" => elevation_profile(sampled)
        }
      end

      # Distance-even resampling of +points+ ([lon, lat, ele] triplets) down
      # to at most MAX_POINTS, always keeping the first and last — the route
      # ends are its most recognizable feature (same strategy as
      # Mapbox::StaticImage's cap). Recording density varies along a real
      # track (1s-sampled files pile points up while the device waits at the
      # start, smart recording thins straight stretches), so sampling by
      # index spends the vertex budget wherever the file happens to be dense
      # and starves the rest of the line. Walking the cumulative ground
      # distance instead puts a vertex roughly every total/MAX_POINTS metres,
      # keeping the drawn shape even end to end. Deterministic, O(n).
      def downsample(points)
        return points if points.size <= MAX_POINTS

        cumulative = cumulative_distance_m(points)
        return [ points.first, points.last ] if cumulative.last <= 0

        step = cumulative.last / (MAX_POINTS - 1)
        last_index = points.size - 1
        sampled = [ points.first ]
        index = 1
        target = 1
        while target <= MAX_POINTS - 2 && index < last_index
          # First vertex at or past the next even share of the track; the
          # forced advance after each emission keeps vertices unique when a
          # dense cluster already sits past several shares at once.
          index += 1 while index < last_index && cumulative[index] < step * target
          break if index >= last_index

          sampled << points[index]
          target += 1
          index += 1
        end
        sampled << points[last_index]
        sampled
      end

      # Cumulative ground distance in metres at each point index
      # (cumulative[0] == 0) — the axis both the line resampling and the
      # profile chart walk. haversine_m reads only [lon, lat].
      def cumulative_distance_m(points)
        cumulative = [ 0.0 ]
        points.each_cons(2).with_index do |(from, to), i|
          cumulative << cumulative[i] + haversine_m(from, to)
        end
        cumulative
      end

      def line_coordinates(points)
        return if points.size < 2

        points.map { |lon, lat, _ele| [ lon, lat ] }
      end

      # [distance_m, elevation_m] pairs for the popup profile: cumulative
      # ground distance along the track (haversine over consecutive sampled
      # points) against each point's elevation. Points without <ele> are
      # skipped; fewer than two elevation readings means no profile. The
      # exact total-distance stat stays on the route columns — the chart is
      # illustrative, so sampling error is acceptable (documented).
      def elevation_profile(points)
        elevated = points.select { |point| !point[2].nil? }
        return if elevated.size < 2

        profile = []
        travelled = 0.0
        previous = nil
        elevated.each do |lon, lat, ele|
          travelled += haversine_m(previous, [ lon, lat ]) if previous
          previous = [ lon, lat ]
          profile << [ travelled.round, ele.round ]
        end
        return profile if profile.size <= PROFILE_BUCKETS

        stride = (profile.size.to_f / PROFILE_BUCKETS).ceil
        sampled = profile.each_slice(stride).map(&:first)
        sampled[-1] = profile[-1]
        sampled
      end

      def haversine_m(from, to)
        lon1, lat1 = from
        lon2, lat2 = to
        phi1 = lat1 * Math::PI / 180
        phi2 = lat2 * Math::PI / 180
        dphi = (lat2 - lat1) * Math::PI / 180
        dlmb = (lon2 - lon1) * Math::PI / 180
        a = Math.sin(dphi / 2)**2 +
            Math.cos(phi1) * Math.cos(phi2) * Math.sin(dlmb / 2)**2
        2 * EARTH_RADIUS_M * Math.asin(Math.sqrt(a))
      end
    end
  end
end
