class AddMapGeometryToRoutes < ActiveRecord::Migration[7.2]
  def change
    # Map page (technote.MYMAP-FEATURE.md §5/§9): the route's drawable line
    # (distance-even resampled to 400 points) and the popup elevation profile
    # (120 buckets), derived once at GPX parse time and stored — so map
    # requests play back stored geometry instead of re-parsing GPX blobs, and
    # cache warmth can no longer change a response's latency (the old lazy
    # Rails.cache entry re-parsed every track on first hit after each dev
    # boot / Redis eviction: ~1s per multi-MB route). Presentation-only
    # derived data: the stats (distance, elevation gain/loss, min/max) are
    # computed from the full series in Route#parse_gpx! and keep living in
    # their own columns — nothing ever reads map_geometry back into stats.
    add_column :routes, :map_geometry, :jsonb
  end
end
