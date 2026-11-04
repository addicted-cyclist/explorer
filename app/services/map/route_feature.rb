# frozen_string_literal: true

module Map
  # Builds the GeoJSON Feature for one route (technote.MYMAP-FEATURE.md §5):
  # a LineString geometry derived from the stored GPX plus the compact
  # property set the Map page needs — title, stats, detail/detail-download
  # URLs, ownership and visibility flags, bounding box and the elevation
  # profile for the popup chart.
  class RouteFeature
    MAX_POINTS = 400
    PROFILE_BUCKETS = 120
    CACHE_VERSION = "v1"

    EARTH_RADIUS_M = 6_371_000.0

    class << self
      # { type: "FeatureCollection", features: [...] } for +routes+. +own+
      # marks every feature as the viewer's; +public_ids+ (own collections
      # only) carries the route ids that are publicly viewable, resolved by
      # the controller in ONE query instead of one EXISTS per route.
      def collection(routes, own:, public_ids: [])
        features = routes.filter_map do |route|
          feature = build(route, own: own)
          feature["properties"]["public"] = own ? public_ids.include?(route.id) : true
          feature
        end
        { "type" => "FeatureCollection", "features" => features }
      end

      # The feature for one route. Routes without a GPX still get a feature
      # (null geometry) so they appear in the drawer with their stats; the
      # public endpoint filters those out via with_track before calling.
      # The cached core is viewer-independent — the per-request "own" flag
      # is merged into a fresh properties hash so the cached object is
      # never mutated (dev's memory cache store hands back the same
      # instance on every fetch).
      def build(route, own:)
        core = cached_core(route)
        {
          "type" => "Feature",
          "id" => core["id"],
          "geometry" => core["geometry"],
          "properties" => core["properties"].merge("own" => own)
        }
      end

      # ---- internals (class-level for the singleton dispatch) --------------

      def cached_core(route)
        return cached_core!(route) if route.gpx_file.attached?

        # No GPX — nothing to draw or profile, but the route still shows in
        # the own drawer with its stats: emit a null-geometry feature
        # (GeoJSON permits it; line layers simply skip it).
        core_for(route, nil, nil)
      end

      def cached_core!(route)
        Rails.cache.fetch(cache_key(route)) do
          points = downsample(route.track_coordinates)
          core_for(route, line_geometry(points), elevation_profile(points))
        end
      rescue StandardError => e
        # A corrupt/unreadable GPX must not break the whole collection —
        # degrade to the null-geometry feature like the import flow's
        # per-file rescue does.
        Rails.logger.warn("Map geometry parse failed for route ##{route.id}: #{e.class} #{e.message}")
        core_for(route, nil, nil)
      end

      # The blob key rotates on every re-attach, so a re-uploaded GPX
      # invalidates its cache entry with no manual sweeping.
      def cache_key(route)
        "map/track/#{CACHE_VERSION}/#{route.id}/#{route.gpx_file.blob.key}"
      end

      def core_for(route, geometry, profile)
        {
          "type" => "Feature",
          "id" => route.id,
          "geometry" => geometry,
          "properties" => {
            "id" => route.id,
            "title" => route.title,
            # The popup shows a short blurb; full text stays on the detail
            # page. Truncation keeps responses compact for long write-ups.
            "description" => route.description.to_s.truncate(300).presence,
            "distance" => route.distance,
            "elevation_gain" => route.elevation_gain,
            "duration" => route.duration,
            "avg_speed_kmh" => route.moving_pace&.round(1),
            "tier" => route.tier,
            "sport_type" => route.sport_type,
            "url" => url_helpers.route_path(route.id),
            "download_url" => url_helpers.download_route_path(route.id),
            "thumb_url" => thumb_url(route),
            "bounds" => route.bounds_array,
            "elevation_profile" => profile
          }
        }
      end

      def url_helpers
        @url_helpers ||= Rails.application.routes.url_helpers
      end

      # The cacheable thumbnail endpoint (same one the library cards use);
      # routes without one render the fallback icon in the drawer.
      def thumb_url(route)
        return unless route.static_map.attached?

        url_helpers.route_static_map_path(route.static_map.blob.signed_id)
      end

      # Stride-sample +points+ ([lon, lat, ele] triplets) down to MAX_POINTS,
      # always keeping the first and last — the route ends are its most
      # recognizable feature (same strategy as Mapbox::StaticImage's cap).
      def downsample(points)
        return points if points.size <= MAX_POINTS

        stride = (points.size.to_f / MAX_POINTS).ceil
        sampled = points.each_slice(stride).map(&:first)
        sampled[-1] = points[-1]
        sampled
      end

      def line_geometry(points)
        return if points.size < 2

        { "type" => "LineString", "coordinates" => points.map { |lon, lat, _ele| [ lon, lat ] } }
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
