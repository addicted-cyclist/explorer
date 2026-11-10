# frozen_string_literal: true

module Map
  # The My Map "most-ridden place" (technote.MYMAP-FEATURE.md §3.1/§3.2) —
  # the densest own-routes hotspot, computed server-side because own routes
  # load per viewport now: the browser never holds the full library a
  # client-side scan would need. Both the page's initial viewport and the
  # heart control's "return to my routes" action land on the place where the
  # rider actually has the most routes, instead of zooming out to frame
  # every track they own.
  #
  # Every route's bounds-box center is one vote: the best-attended route —
  # the one with the most other centers within HOTSPOT_RADIUS_KM — anchors
  # the hotspot, and the union box of that group comes back as a plain
  # [w, s, e, n] array for map.fitBounds. So a neighbourhood with five short
  # rides beats one long tour that merely passes through, the answer cannot
  # be split by an arbitrary grid, ties resolve to the route seen first
  # (stable :id order), and a rider without any usable bounds gets nil so
  # the client falls back to its persisted/geolocation/default view.
  #
  # Own-routes scale only (a user's own list), so the O(n²) neighbourhood
  # scan is comfortably cheap and keeps the algorithm grid-artifact-free.
  class OwnRoutesHotspot
    # "A place": routes centered within this distance of each other belong to
    # the same hotspot. ~5 km covers a city centre or a trailhead area.
    HOTSPOT_RADIUS_KM = 5.0
    KM_PER_DEG_LAT = 110.574
    KM_PER_DEG_LNG = 111.32

    class << self
      # [west, south, east, north] for the hotspot group, or nil when +routes+
      # carries no parsed bounds. Reads only the four bounds columns — one
      # light query, no GPX blobs involved.
      def bounds(routes)
        boxes = routes.where.not(min_lat: nil)
                      .order(:id)
                      .pluck(:min_lon, :min_lat, :max_lon, :max_lat)
        return if boxes.empty?

        group = best_neighbourhood(boxes.map { |box| center_of(box) })
        group_boxes = boxes.values_at(*group)
        [
          group_boxes.map { |box| box[0] }.min,
          group_boxes.map { |box| box[1] }.min,
          group_boxes.map { |box| box[2] }.max,
          group_boxes.map { |box| box[3] }.max
        ]
      end

      private

      # Bounding-box center as [lon, lat] — the route's single vote.
      def center_of(box)
        [ (box[0] + box[2]) / 2.0, (box[1] + box[3]) / 2.0 ]
      end

      # Indexes of the group around the best anchor. Longitude degrees shrink
      # with latitude, so distances use the equirectangular approximation
      # (fine at 5 km). Ties keep the earlier anchor — stable over the
      # :id-ordered query.
      def best_neighbourhood(centers)
        radius_sq = HOTSPOT_RADIUS_KM * HOTSPOT_RADIUS_KM
        best = nil
        centers.each_with_index do |anchor, index|
          group = [ index ]
          km_per_deg_lng = KM_PER_DEG_LNG * Math.cos(anchor[1] * Math::PI / 180)
          centers.each_with_index do |center, other|
            next if other == index

            dx = (center[0] - anchor[0]) * km_per_deg_lng
            dy = (center[1] - anchor[1]) * KM_PER_DEG_LAT
            group << other if dx * dx + dy * dy <= radius_sq
          end
          best = group if best.nil? || group.size > best.size
        end
        best
      end
    end
  end
end
