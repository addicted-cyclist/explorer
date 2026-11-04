class AddMapBoundsToRoutes < ActiveRecord::Migration[7.2]
  def change
    # Map page (technote.MYMAP-FEATURE.md §5.1): the track's geographic
    # bounding box, captured at GPX parse time from the same trackpoints the
    # stats parse already reads. Lets the public-routes query select routes
    # intersecting the requested viewport in SQL instead of parsing every
    # public GPX on each pan. Plain float columns + the existing user_id
    # index are deliberately enough for Stage 1 volumes — no spatial index
    # or PostGIS dependency (§5.2: "avoid introducing a complex spatial
    # database migration unless it is necessary").
    add_column :routes, :min_lon, :float
    add_column :routes, :max_lon, :float
    add_column :routes, :min_lat, :float
    add_column :routes, :max_lat, :float
  end
end
