# frozen_string_literal: true

# Centralized base-map configuration for the Map page
# (technote.MYMAP-FEATURE.md §7 "Map Style and Tile Provider Configuration").
#
# Everything provider-specific — style URL, API key handling, attribution —
# lives here and nowhere else. Route rendering
# (app/javascript/controllers/my_map_controller.js) only consumes the values
# resolved below and adds its own GeoJSON sources/layers on top of whatever
# style loads, so switching providers is a change to this file (or an env
# var) and nothing else — never to route-rendering code.
#
# Style resolution order:
#   1. credentials :map/:style_url  — keeps secrets out of ENV/shell history.
#   2. ENV MAP_STYLE_URL            — 12-factor deploys; the URL carries any
#                                     provider key embedded (e.g. MapTiler's
#                                     "?key=..."). Blank values (dokploy passes
#                                     an unset compose var through as "") fall
#                                     through to the default below.
#   3. OpenFreeMap Liberty          — keyless final default
#                                     (https://openfreemap.org) so /map
#                                     renders a real base map in fresh
#                                     environments with zero signup.
#
# Classic Mapbox style URLs (api.mapbox.com/styles/v1/...) deliberately do
# not appear above. They are NOT MapLibre-compatible: sources/sprite/glyphs
# use the proprietary mapbox:// scheme MapLibre cannot resolve, and the
# documents Mapbox serves now carry Studio-only root properties (e.g.
# projection: { "name": "globe" }) that make MapLibre abort the style load
# with `name: unknown property "name"` — leaving /map blank.
#
# The same resolved style also feeds the Step 2 client-side thumbnail
# renderer (app/javascript/map/route_thumb_capture.js), so route thumbs and
# the /map page always share one provider configuration. There is no server
# thumbnail dependency left — Mapbox::StaticImage and MAPBOX_ACCESS_TOKEN
# are retired (thumbs are captured in the browser and POSTed to
# /routes/:id/static_map).
#
# Evaluated at boot; a style change needs an app restart.
Rails.application.config.x.map =
  {
    # MapLibre `style:` accepts a style-document URL or an inline style
    # object; the client falls back to its minimal background-only style
    # when this resolves to nil.
    style_url:
      Rails.application.credentials.dig(:map, :style_url).presence ||
      ENV["MAP_STYLE_URL"].presence ||
      "https://tiles.openfreemap.org/styles/liberty",
    # Extra attribution rendered beside whatever the style JSON already
    # carries (tile providers require it; OpenFreeMap styles ship their own).
    custom_attribution: nil,
    # Viewport used when the user has no routes, no persisted viewport and
    # geolocation is unavailable or denied (§3.1: "initially Da Nang,
    # Vietnam"). [lng, lat].
    default_center: [ 108.2022, 16.0544 ],
    default_zoom: 12.0,
    # Cap for the fit-to-my-routes initial view (§3.1: avoid excessive zoom
    # for routes with very small geographic extents).
    fit_max_zoom: 14.0,
    # Sub-bar location chip label (design-refs/stitch_explorer_v0.14).
    # Rendered server-side as the fallback; rewritten client-side from the
    # reverse geocoder below as the viewport moves.
    default_place_label: "Da Nang & Coastal Ridges, VN",
    # Reverse geocoder for the sub-bar location chip (Photon — komoot's
    # OpenStreetMap geocoder). The keyless public instance is the default;
    # a self-hosted Photon (komoot/photon, e.g. http://localhost:2322)
    # swaps in via credentials :map/:geocoder_url or ENV MAP_GEOCODER_URL
    # (blank ENV values fall through to the default). Map::ReverseGeocoder
    # appends /reverse to this base URL.
    geocoder_url:
      Rails.application.credentials.dig(:map, :geocoder_url).presence ||
      ENV["MAP_GEOCODER_URL"].presence ||
      "https://photon.komoot.io",
    # Language of the geocoder's place names (Photon `lang` param).
    geocoder_lang: "en",
    # Zoom below which /map skips the public-routes fetch entirely: the §5.1
    # 500-cap makes regional/country-scale fetches a truncated head at best,
    # replaced the moment the rider zooms in — the client deltas from there.
    public_min_zoom: 8.5
  }.freeze
