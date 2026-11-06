# frozen_string_literal: true

module Map
  # Reverse geocoding for the My Map sub-bar location chip: turns the
  # viewport center's lon/lat into a human "City, Region, Country" label via
  # Photon — komoot's OpenStreetMap geocoder. The keyless public instance
  # (photon.komoot.io) is the default; a self-hosted Photon replaces it
  # through config/initializers/map.rb (geocoder_url) with zero code
  # changes, keeping provider specifics out of the request flow (§7).
  #
  # Only the administrative hierarchy (city/town/village/…, state, country)
  # feeds the label — never the nearest object's own name — so a reverse hit
  # on a street or an ATM still answers "where am I" at place granularity,
  # and the label reads the same at every zoom.
  #
  # Politeness: the public instance throttles extensive usage, while panning
  # settles a request per camera move. Results are therefore cached per
  # ~1.1 km grid cell (2-decimal lon/lat — the label never resolves finer
  # than city/region anyway): successes for half a day, upstream failures
  # for a minute so an outage doesn't turn every pan into another hit.
  class ReverseGeocoder
    SUCCESS_TTL = 12.hours
    FAILURE_TTL = 1.minute
    # Decimals of lon/lat kept in the cache key: 2 ≈ 1.1 km cells.
    CACHE_ROUNDING = 2
    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 4
    # The public Photon instance 403s generic library User-Agents (Net::HTTP
    # sends "Ruby") — and fair use etiquette asks clients to identify
    # themselves anyway.
    USER_AGENT = "Explorer/1.0 (My Map location chip)".freeze

    # Address-hierarchy property names Photon ships on every feature, tried
    # most specific place first; anything finer (street, house, postcode) is
    # deliberately not part of the chip.
    PLACE_FIELDS = %w[city town village hamlet municipality county district suburb quarter locality].freeze
    REGION_FIELDS = %w[state].freeze
    COUNTRY_FIELDS = %w[country].freeze

    class << self
      # "City, Region, Country" for +lon+/+lat+, or nil when Photon can't
      # answer (no feature, upstream error). +http:+ injects the GET
      # dependency (call(url) → body string) for tests; production uses
      # Net::HTTP.
      def label(lon, lat, http: method(:http_get))
        key = cache_key(lon, lat)
        cached = Rails.cache.read(key)
        return cached.presence unless cached.nil?

        label = build_label(photon_properties(lon, lat, http))
        # "" marks a failure in the cache — Rails.cache treats nil as a
        # miss, which would re-hit Photon on every pan during an outage.
        Rails.cache.write(key, label || "", expires_in: label ? SUCCESS_TTL : FAILURE_TTL)
        label
      end

      private

      def cache_key(lon, lat)
        "map:reverse-geocoder:#{lon.round(CACHE_ROUNDING)}:#{lat.round(CACHE_ROUNDING)}"
      end

      # Duplicate tiers collapse (a municipality whose state shares its
      # name, city-states): "Da Nang, Đà Nẵng, Vietnam" would repeat itself.
      def build_label(properties)
        return nil unless properties

        [ first_value(properties, PLACE_FIELDS),
          first_value(properties, REGION_FIELDS),
          first_value(properties, COUNTRY_FIELDS) ]
          .compact.uniq(&:downcase).join(", ").presence
      end

      def first_value(properties, fields)
        value = fields.filter_map { |field| properties[field] }.first
        value if value.present?
      end

      def photon_properties(lon, lat, http)
        query = URI.encode_www_form(lon: lon, lat: lat, lang: geocoder_lang, limit: 1)
        JSON.parse(http.call("#{geocoder_url}/reverse?#{query}"))
            .dig("features", 0, "properties")
      rescue StandardError => error
        # Offline Photon, throttling, garbage payload: degrade to nil — the
        # controller answers place_label: null and the client keeps the
        # label it has instead of blanking the chip.
        Rails.logger.warn("Photon reverse geocode failed for #{lon},#{lat}: #{error.class}: #{error.message}")
        nil
      end

      def http_get(url)
        uri = URI(url)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                   open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
          http.request(Net::HTTP::Get.new(
            uri, "Accept" => "application/json", "User-Agent" => USER_AGENT
          ))
        end
        raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        response.body
      end

      def geocoder_url
        Rails.application.config.x.map[:geocoder_url]
      end

      def geocoder_lang
        Rails.application.config.x.map[:geocoder_lang] || "en"
      end
    end
  end
end
