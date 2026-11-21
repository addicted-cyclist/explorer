# frozen_string_literal: true

# Centralized routing-engine configuration for the Route Planner
# (technote.ROUTE-DRAW.md §10.4). Everything BRouter-specific — endpoint,
# profile naming, timeouts, cache lifetime — resolves here and nowhere else:
# Routing::BrouterClient only consumes the values below, so pointing the app
# at a different internal BRouter instance (or renaming profiles) is a change
# to this file or an env var, never to planner code.
#
# The endpoint must stay internal: the BRouter container is only reachable
# from the app's private compose network (docker-compose.yml) and the
# frontend NEVER talks to BRouter directly — every routing request flows
# through PlannerController → Routing::BrouterClient.
#
# Resolution order for the base URL:
#   1. credentials :routing/:brouter_url — keeps internal topology out of
#      ENV/shell history.
#   2. ENV BRROUTER_URL — 12-factor deploys (dokploy Environment tab).
#   3. http://brouter:17777/brouter — the compose service name; in
#      development without the container, override with
#      BRROUTER_URL=http://localhost:17777/brouter.
Rails.application.config.x.routing =
  {
    # BRouter HTTP endpoint (RouteServer). Routing requests append the query
    # string (?lonlats=...&profile=...&format=geojson).
    base_url:
      Rails.application.credentials.dig(:routing, :brouter_url).presence ||
      ENV["BRROUTER_URL"].presence ||
      "http://brouter:17777/brouter",
    # Profile names as addressed INSIDE BRouter. Profiles ship in
    # brouter/profiles/*.brf, mounted read-only at the container's
    # CUSTOMPROFILESPATH (/customprofiles); BRouter's server resolves a
    # profile request starting with "custom_" inside that directory
    # (ServerHandler#readRoutingContext → ProfileUploadHandler.CUSTOM_PREFIX).
    # Keys are the app-level Route::ROUTING_PROFILES values.
    profiles: {
      "road" => "custom_road",
      "gravel" => "custom_gravel",
      "mtb" => "custom_mtb"
    }.freeze,
    # Seconds the adapter waits for BRouter per phase (connect / write /
    # read). Routing must feel interactive: past this budget the segment
    # request is abandoned, the last valid geometry stays on screen (§10.6)
    # and the user gets a retryable error.
    open_timeout: 2.0,
    read_timeout: 20.0,
    # Identical routing requests are served from the cache store (Redis in
    # production, §10.6): the key rounds coordinates to 5 decimals (~1 m), so
    # the same drag point never recomputes, saves replay the session's
    # calculations for free, and warmth cannot change response shape.
    cache_ttl: 6.hours,
    # Cap on the number of lonlats a single segment request may carry
    # (RW + its shaping points + closing RW).
    max_points_per_request: 120
  }.freeze
