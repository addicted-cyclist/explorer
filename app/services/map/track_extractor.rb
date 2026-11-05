# frozen_string_literal: true

module Map
  # Fast streaming extraction of a GPX track's usable points as [lon, lat, ele]
  # triplets — the geometry source for the Map page (technote.MYMAP-FEATURE.md
  # §5). The stats parse (Route#parse_gpx!) keeps the gpx gem because distance,
  # duration and the elevation stats need its full point tree; drawing a line
  # does not, and the gem's parse (a TrackPoint object, several Nokogiri node
  # lookups and a Time parse per trackpoint, plus a haversine per consecutive
  # pair) measured ~1.2s per 2.4MB track against ~0.2s here. This reader walks
  # the document once with a SAX handler and collects only what the line and
  # the profile chart need.
  #
  # Coordinates are rounded at the source — 5 decimal places (~1.1m) for
  # lon/lat, 1 for elevation — indistinguishable on the map and in the chart,
  # but materially smaller in the stored geometry and every response that
  # ships it. Malformed documents raise ParseError; callers degrade the same
  # way the import flow's per-file rescue does (no geometry, request survives).
  class TrackExtractor
    LON_LAT_PRECISION = 5
    ELE_PRECISION = 1

    # Raised for unreadable or malformed GPX input. Callers rescue it to
    # degrade to a null-geometry feature (Map::RouteFeature) or a per-row
    # failure (backfill tasks) — never to fail a request or a whole task.
    class ParseError < StandardError; end

    class << self
      # [lon, lat, ele] triplets from +source+ — an open IO, a file path, or a
      # string of XML — in document order. ele is nil for trackpoints without
      # an <ele> element. Trackpoints without both lon and lat are skipped;
      # waypoints and routes never contribute. Empty (not nil) when nothing is
      # usable, so callers can iterate unconditionally.
      def extract(source)
        handler = Handler.new
        parser = Nokogiri::XML::SAX::Parser.new(handler)
        # Dispatch by what the source really is — Nokogiri's parse_io misfeeds
        # path-like objects (a Pathname surfaces "XML declaration allowed only
        # at the start of the document"), so only true IO-likes go there. Open
        # File/Tempfile handles hand their to_path to parse_file (to_s is
        # "#<File:...>", never a path); XML strings miss File.exist? and land
        # in parse_memory.
        if source.respond_to?(:read) && !source.respond_to?(:to_path)
          parser.parse_io(source)
        else
          path = source.respond_to?(:to_path) ? source.to_path : source.to_s
          if File.exist?(path)
            parser.parse_file(path)
          else
            parser.parse_memory(path.to_s)
          end
        end
        # SAX parsers recover from malformed input instead of raising — the
        # parse errors arrive on the handler, where the DOM-based stats parse
        # would have raised SyntaxError. Keep that contract: a malformed
        # document never yields a silently partial track.
        raise ParseError, "GPX track extraction failed: malformed XML (#{handler.errors.first})" if handler.errors.any?

        handler.points
      rescue Nokogiri::XML::SyntaxError, IOError, SystemCallError, ArgumentError => e
        raise ParseError, "GPX track extraction failed: #{e.class}: #{e.message}"
      end
    end

    # SAX event sink: collects trkpt triplets. Text is buffered because
    # Nokogiri may deliver one text node across several character callbacks.
    class Handler < Nokogiri::XML::SAX::Document
      attr_reader :points, :errors

      def initialize
        super()
        @points = []
        @errors = []
        @in_trkpt = false
        @in_ele = false
        @text = +""
        @lon = nil
        @lat = nil
        @ele = nil
      end

      # Recoverable-parse diagnostics (SAX does not raise on malformed input);
      # extract turns any of these into a ParseError.
      def error(string)
        @errors << string
      end

      def start_element(name, attrs = [])
        case local_name(name)
        when "trkpt"
          @in_trkpt = true
          attributes = attrs.to_h
          @lon = float(attributes["lon"])
          @lat = float(attributes["lat"])
          @ele = nil
        when "ele"
          # Only a trackpoint's own <ele> counts — a waypoint's must never
          # bleed into the next track's geometry.
          @in_ele = @in_trkpt
          @text.clear
        end
      end

      def characters(string)
        @text << string if @in_ele
      end

      # <ele> is plain text in legal GPX, but real files defy specs.
      alias_method :cdata_block, :characters

      def end_element(name)
        case local_name(name)
        when "ele"
          @ele = float(@text) if @in_ele
          @in_ele = false
        when "trkpt"
          if @lon && @lat
            @points << [ @lon.round(LON_LAT_PRECISION), @lat.round(LON_LAT_PRECISION),
                         @ele&.round(ELE_PRECISION) ]
          end
          @in_trkpt = false
          @lon = @lat = @ele = nil
        end
      end

      private

      # Prefixed-namespace documents (legal, if rare) arrive as
      # "prefix:trkpt"; the stats parse's XPath matches by local name, so the
      # extractor keeps parity.
      def local_name(name)
        name.include?(":") ? name.rpartition(":").last : name
      end

      # Strict float parse: "", whitespace and garbage become nil, while
      # "0" stays 0.0 — a legitimate equator/Greenwich coordinate never drops.
      def float(raw)
        Float(raw, exception: false) if raw
      end
    end
  end
end
