# frozen_string_literal: true

module Map
  # Builds the GeoJSON Feature for one route (technote.MYMAP-FEATURE.md §5):
  # a LineString geometry from the route's stored map geometry plus the
  # compact property set the Map page needs — title, stats, detail/detail-
  # download URLs, ownership and visibility flags, bounding box and the
  # elevation profile for the popup chart.
  #
  # Geometry is precomputed at parse time (routes.map_geometry — written by
  # Route#parse_gpx! and the map-geometry backfill), so no request parses a
  # GPX blob and cache warmth cannot change a response's latency. Only the
  # geometry is stored: properties are rebuilt from the live route columns on
  # every build, so detail-page edits (title, tier, ...) show up on the map
  # immediately.
  class RouteFeature
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
      def build(route, own:)
        coordinates = stored_coordinates(route)
        {
          "type" => "Feature",
          "id" => route.id,
          "geometry" => coordinates && { "type" => "LineString", "coordinates" => coordinates },
          "properties" => properties_for(route).merge("own" => own)
        }
      end

      # ---- internals (class-level for the singleton dispatch) --------------

      # The stored drawn line (routes.map_geometry "coordinates"), deriving
      # and persisting it once for rows the backfill has not reached yet
      # (self-heal: every writer computes the same value, so the parse cost
      # is paid exactly once per route and no request ever waits twice).
      # Nil for GPX-less routes — the drawer still shows their stats, the
      # line layers simply skip the feature.
      def stored_coordinates(route)
        geometry = route.map_geometry
        return geometry["coordinates"] if geometry.present?
        return unless route.gpx_file.attached?

        geometry = Map::TrackGeometry.build(route.track_coordinates)
        route.update_columns(map_geometry: geometry)
        geometry["coordinates"]
      rescue StandardError => e
        # A corrupt/unreadable GPX must not break the whole collection —
        # degrade to the null-geometry feature like the import flow's
        # per-file rescue does. Nothing is persisted here, so a re-parse
        # (re-upload) or a backfill re-run recovers it.
        Rails.logger.warn("Map geometry derivation failed for route ##{route.id}: #{e.class} #{e.message}")
        nil
      end

      def properties_for(route)
        geometry = route.map_geometry
        {
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
          "elevation_profile" => geometry && geometry["profile"]
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
    end
  end
end
