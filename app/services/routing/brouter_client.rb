# frozen_string_literal: true

module Routing
  # The Routing Engine Adapter (technote.ROUTE-DRAW.md §10.4): the ONLY code
  # path between the application and the self-hosted BRouter HTTP server.
  # Converts RW/SP coordinate sequences into BRouter requests, parses the
  # responses into the application's GeoJSON shape, caches identical
  # requests, and translates every failure mode into a small set of
  # user-safe errors. BRouter implementation details never leak past this
  # class, and the frontend never talks to BRouter — it talks to
  # PlannerController, which delegates here.
  #
  # BRouter specifics handled here (verified against abrensch/brouter):
  #   * GET {base}?lonlats=lon,lat|lon,lat&profile=NAME&alternativeidx=0
  #     &format=geojson
  #   * profile NAME "custom_xxx" resolves inside the container's custom
  #     profiles dir (see config/initializers/routing.rb)
  #   * 200 responses are a GeoJSON FeatureCollection whose first feature
  #     carries the LineString (geometry coordinates [lon, lat, ele] when
  #     elevation data is installed) and properties "track-length" (metres,
  #     string) / "filtered ascend" (metres, string) / "total-time" (seconds)
  #   * routing failures (no data, unreachable snap) still answer 200 with a
  #     plain-text error body — so a body that does not parse as GeoJSON with
  #     a LineString is a RequestFailed, and HTTP-level failures are
  #     Unavailable
  class BrouterClient
    # User-safe failures (§10.4: handle timeouts, invalid requests, routing
    # failures). #message is rendered to the planner UI verbatim.
    class Error < StandardError; end
    class Unavailable < Error; end
    class RequestFailed < Error; end

    # One calculated segment. coordinates are [lon, lat, ele] triplets (ele
    # nil when BRouter returned 2D points), distance_m/ascend_m/time_s the
    # engine-reported totals.
    Segment = Struct.new(:coordinates, :distance_m, :ascend_m, :time_s, keyword_init: true)

    class << self
      # Route a single segment through BRouter: +points+ are [lat, lon]
      # control points (RW with any SPs spliced in order, closing RW last),
      # +profile+ one of Route::ROUTING_PROFILES. Cached by rounded
      # coordinates + profile (§10.6: identical requests must not recompute).
      def calculate_segment(points:, profile:)
        validate_points!(points)
        cache_key = segment_cache_key(points, profile)
        cached = Rails.cache.read(cache_key)
        return cached if cached

        segment = request_segment(points, profile)
        Rails.cache.write(cache_key, segment, expires_in: Rails.application.config.x.routing[:cache_ttl])
        segment
      end

      private

      def validate_points!(points)
        max = Rails.application.config.x.routing[:max_points_per_request]
        unless points.is_a?(Array) && points.size.between?(2, max)
          raise ArgumentError, "a segment needs 2 to #{max} points"
        end

        valid = points.all? do |point|
          point.is_a?(Array) && point.size == 2 &&
            point[0].between?(-90.0, 90.0) && point[1].between?(-180.0, 180.0)
        end
        raise ArgumentError, "every point needs a lat/lon pair" unless valid
      end

      def segment_cache_key(points, profile)
        rounded = points.map { |lat, lon| [ lat.round(5), lon.round(5) ] }
        "routing/seg/v1/#{profile}/#{rounded.map { |point| point.join(',') }.join('|')}"
      end

      def request_segment(points, profile)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        segment = parse(http_get(request_url(points, profile)))
        log_routing(points, profile, started, "ok")
        segment
      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH,
             SocketError, EOFError, OpenSSL::SSL::SSLError => e
        log_routing(points, profile, started, "unavailable: #{e.class}")
        raise Unavailable, "Routing service is not responding — try again in a moment."
      end

      def request_url(points, profile)
        brouter_profile = Rails.application.config.x.routing[:profiles].fetch(profile) do
          raise ArgumentError, "unknown routing profile: #{profile}"
        end
        lonlats = points.map { |lat, lon| format("%.6f,%.6f", lon, lat) }.join("|")
        "#{base_url}?lonlats=#{URI.encode_www_form_component(lonlats)}" \
          "&profile=#{brouter_profile}&alternativeidx=0&format=geojson"
      end

      def http_get(url)
        uri = URI(url)
        config = Rails.application.config.x.routing
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = config[:open_timeout]
        http.write_timeout = config[:read_timeout]
        http.read_timeout = config[:read_timeout]
        response = http.get("#{uri.path}?#{uri.query}", "Accept" => "application/geo+json")
        unless response.is_a?(Net::HTTPSuccess)
          log_line("http_status=#{response.code}")
          raise Unavailable, "Routing service returned an error (#{response.code})."
        end

        response.body
      end

      # BRouter answers routing failures with HTTP 200 and a non-GeoJSON
      # body ("datafile ... not found", snapping errors, ...) — parse must
      # treat any of those as a failed request, never as an empty route.
      def parse(body)
        payload = JSON.parse(body)
        feature = payload.is_a?(Hash) && payload["features"].is_a?(Array) && payload["features"][0]
        geometry = feature.is_a?(Hash) && feature["geometry"]
        if !geometry.is_a?(Hash) || geometry["type"] != "LineString" ||
           !geometry["coordinates"].is_a?(Array) || geometry["coordinates"].size < 2
          raise RequestFailed, parse_failure_message(body)
        end

        properties = feature["properties"].is_a?(Hash) ? feature["properties"] : {}
        Segment.new(
          coordinates: geometry["coordinates"].map { |lon, lat, ele| [ lon, lat, ele.nil? ? nil : ele.to_f ] },
          distance_m: properties["track-length"].to_f,
          ascend_m: properties["filtered ascend"].to_f,
          time_s: properties["total-time"].to_f
        )
      rescue JSON::ParserError
        raise RequestFailed, parse_failure_message(body)
      end

      def parse_failure_message(body)
        if body.to_s.match?(/datafile.*not found/i)
          "Routing data for this area is not installed yet."
        else
          "No route could be calculated for this segment — try moving the points closer to roads."
        end
      end

      def log_routing(points, profile, started, outcome)
        elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        log_line("points=#{points.size} profile=#{profile} outcome=#{outcome} duration_ms=#{elapsed_ms}")
      end

      # §10.8: routing request logs + execution time + failed request count
      # (grep planner/routing in the Rails log; the BRouter container adds
      # its own access log and health status).
      def log_line(details)
        Rails.logger.info("[planner/routing] #{details}")
      end

      def base_url
        Rails.application.config.x.routing[:base_url].delete_suffix("/")
      end
    end
  end
end
