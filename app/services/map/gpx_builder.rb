# frozen_string_literal: true

module Map
  # Builds the GPX representation of a drawn route (technote.ROUTE-DRAW.md
  # §9): the calculated geometry with one <trkpt> per point, elevations when
  # BRouter provided them. The GPX is NOT the source of truth for editing —
  # the RW/POI collections are (§3, §12) — but attaching it makes a drawn
  # route a first-class citizen of the existing machinery: detail page,
  # gpx.studio embed, download, calendar joins and thumbnail capture all
  # read the attachment exactly like an uploaded ride.
  class GpxBuilder
    # GPX 1.1 document for +points+ ([lon, lat, ele] triplets, ele nullable).
    # Hand-built XML on purpose: the document is flat and tiny, and pulling
    # in a builder for six element names would only slow the save path.
    def self.build(title:, points:, description: nil)
      new(title: title, points: points, description: description).build
    end

    def initialize(title:, points:, description: nil)
      @title = title
      @description = description
      @points = points
    end

    def build
      <<~GPX
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="expl.pro" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>#{escape(@title)}</name>#{metadata_description}
          </metadata>
          <trk>
            <name>#{escape(@title)}</name>
            <trkseg>#{track_points}</trkseg>
          </trk>
        </gpx>
      GPX
    end

    private

    def metadata_description
      return "" if @description.blank?

      "\n            <desc>#{escape(@description)}</desc>"
    end

    def track_points
      @points.filter_map do |lon, lat, ele|
        elevation = ele.nil? ? "" : "\n        <ele>#{format("%.2f", ele)}</ele>"
        "\n      <trkpt lat=\"#{format('%.7f', lat)}\" lon=\"#{format('%.7f', lon)}\">#{elevation}\n      </trkpt>"
      end.join
    end

    def escape(text)
      CGI.escapeHTML(text.to_s)
    end
  end
end
