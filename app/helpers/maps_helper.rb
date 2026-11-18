module MapsHelper
  # The resolved Map-page config (config/initializers/map.rb) handed to the
  # my-map Stimulus controller as one JSON value — the client never reads
  # ENV/credentials and route rendering stays provider-agnostic (§7).
  def map_frontend_config
    config = Rails.application.config.x.map
    {
      styleUrl: config[:style_url],
      customAttribution: config[:custom_attribution],
      defaultCenter: config[:default_center],
      defaultZoom: config[:default_zoom],
      fitMaxZoom: config[:fit_max_zoom],
      publicMinZoom: config[:public_min_zoom],
      defaultPlaceLabel: config[:default_place_label]
    }
  end

  # "Find new routes" sport categories for the filter modal — read from
  # Map::RouteFinder::SPORT_CATEGORIES, the single definition of the
  # categories (labels + SQL patterns). The modal's segment buttons and the
  # drawer's chip copy both consume this list, so a new category server-side
  # appears in the UI without touching ERB or JS.
  #
  # [{ key: "road", label: "Road cycling" }, ...] — "all" is added by the
  # view's own leading button since it is a UI concept, not a category.
  def find_sport_categories
    Map::RouteFinder::SPORT_CATEGORIES.map do |key, category|
      { key: key, label: category[:label] }
    end
  end
end
