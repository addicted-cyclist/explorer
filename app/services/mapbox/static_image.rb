# frozen_string_literal: true

module Mapbox
  # Renders the route thumbnail via the Mapbox Static Images API: a real map
  # crop with the route drawn on it, replacing the old abstract SVG "thread"
  # (technote.FEATURES.md — "draw normal route thumb, not only route thread").
  #
  # The render is fetched ONCE at GPX parse time and stored as the route's
  # +static_map+ Active Storage attachment — the same persist-the-derived-data
  # contract the old SVG path data had — so card renders never call Mapbox and
  # a Mapbox outage can neither slow a page down nor fail an upload.
  #
  # Without a token (credentials :mapbox/:access_token, or ENV
  # MAPBOX_ACCESS_TOKEN) every call returns nil: no thumb is attached and the
  # views fall back to the route icon, so dev and tests never touch the
  # network.
  class StaticImage
    # Classic styles only — the Static Images API does not support the newer
    # Standard styles. outdoors-v12 shows trails and terrain, the closest
    # match for cycling/hiking routes.
    STYLE = "mapbox/outdoors-v12"

    # 3:1 render at 2x device pixels. The four thumb boxes this image is
    # cover-cropped into: my-routes card 334x144 (2.3:1), desktop calendar
    # sidebar 240x56 (4.3:1), friend card 350x88 (4:1), mobile calendar
    # 328x88 (3.7:1). 3:1 sits between them, so object-fit: cover never
    # trims more than ~30% of one axis (the 2.3:1 box trims the sides, the
    # ~4:1 boxes the top/bottom).
    WIDTH = 720
    HEIGHT = 240
    RETINA = "@2x"

    # Auto-fit padding in CSS order (vertical, horizontal), sized so the
    # auto-fitted track (plus its stroke) stays clear of the cover-cropped
    # edges:
    #   * worst horizontal crop — the 334x144 box shows 557/720 of the
    #     width, i.e. 82px per side; 86 covers that plus the stroke.
    #   * worst vertical crop — the 240x56 sidebar shows 168/240 of the
    #     height, i.e. 36px per side; 40 covers that plus the stroke.
    # (A uniform padding would need 86 on both axes and would letterbox tall
    # tracks far too aggressively.)
    PADDING = "40,86"

    # Track line style, applied via the GeoJSON overlay's SimpleStyle
    # properties (plain stroke color/width — no path-syntax encoding).
    STROKE_COLOR = "#e11d48"
    STROKE_WIDTH = 5

    # The GeoJSON LineString overlay replaces the classic
    # path-<color>-<width>(<encoded polyline>) overlay: during rollout Mapbox
    # answered HTTP 422 "Invalid path syntax" for every path overlay request —
    # including the verbatim example from their own docs — while GeoJSON
    # rendered the same tracks fine. GeoJSON also carries exact coordinates
    # instead of 1e5-rounded polyline deltas. MAX_POINTS still caps the URL:
    # a full-day track at 1s sampling would exceed the API's URL length limit.
    MAX_POINTS = 200

    class << self
      # An Active Storage attachable hash ({ io:, filename:, content_type: })
      # for +coords+ ([lon, lat] pairs), or nil when there is no token, too
      # few usable points, or the request fails. Never raises: callers treat
      # nil as "no thumb this time" and the upload/import flows keep
      # succeeding — the route simply shows the fallback icon.
      def attachable(coords)
        return unless coords && coords.size >= 2
        return unless access_token

        bytes = fetch_png(build_url(downsample(coords)))
        return unless bytes

        { io: StringIO.new(bytes), filename: "static-map.png", content_type: "image/png" }
      end

      # Token resolution: Rails credentials first (keeps the secret out of
      # ENV/shell history), then the environment variable for 12-factor
      # deploys and CI.
      def access_token
        Rails.application.credentials.dig(:mapbox, :access_token) || ENV["MAPBOX_ACCESS_TOKEN"]
      end

      private

      # Thin the coordinate list to at most MAX_POINTS pairs, keeping the
      # first and last points of the track (the route ends are its most
      # recognizable feature).
      def downsample(coords)
        return coords if coords.size <= MAX_POINTS

        stride = (coords.size.to_f / MAX_POINTS).ceil
        sampled = coords.each_slice(stride).map(&:first)
        sampled[-1] = coords[-1]
        sampled
      end

      def build_url(coords)
        # The GeoJSON payload is percent-encoded aggressively
        # (ERB::Util.url_encode keeps only RFC 3986 unreserved characters)
        # because it contains quotes, braces and the "#" of the stroke color —
        # a stray "#" or "?" would otherwise cut the overlay off mid-URL.
        overlay = "geojson(#{ERB::Util.url_encode(line_geojson(coords))})"
        query = URI.encode_www_form(access_token: access_token, padding: PADDING)

        "https://api.mapbox.com/styles/v1/#{STYLE}/static/#{overlay}/auto/#{WIDTH}x#{HEIGHT}#{RETINA}?#{query}"
      end

      # SimpleStyle properties carry the app's track accent so the overlay
      # needs no path-syntax-specific encoding. [lon, lat] order matches both
      # the GeoJSON spec and the coords the stats parse already produces.
      #
      # The geometry must be wrapped in a Feature: "properties" is not a
      # valid geometry member, and Mapbox silently ignores simplestyle sent
      # on a bare geometry, drawing its default dark ~2px line instead (the
      # "black and thin" track bug). Pixel-probed: only the Feature form
      # renders stroke/stroke-width (it honors stroke-opacity too, but full
      # opacity needs no property).
      def line_geojson(coords)
        {
          type: "Feature",
          properties: { stroke: STROKE_COLOR, "stroke-width": STROKE_WIDTH },
          geometry: { type: "LineString", coordinates: coords }
        }.to_json
      end

      def fetch_png(url)
        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 10

        response = http.get(uri.request_uri)
        return response.body if response.is_a?(Net::HTTPSuccess)

        Rails.logger.warn("Mapbox static image request failed: HTTP #{response.code} for #{uri.host}#{uri.path}")
        nil
      rescue StandardError => e
        Rails.logger.warn("Mapbox static image request error: #{e.class} #{e.message}")
        nil
      end
    end
  end
end
