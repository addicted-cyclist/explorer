# The abstract SVG route-thread thumbnails are replaced by real Mapbox static
# map images stored as the route's :static_map Active Storage attachment (see
# Mapbox::StaticImage). The derived SVG path data column — and every method
# that wrote it — is removed.
class RemoveTrackSvgFromRoutes < ActiveRecord::Migration[7.2]
  def change
    remove_column :routes, :track_svg, :text
  end
end
