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
end
