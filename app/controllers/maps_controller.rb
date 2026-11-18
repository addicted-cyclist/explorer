# My Map page + its GeoJSON data endpoints (technote.MYMAP-FEATURE.md).
#
# Authorization contract:
#   * All three actions sit behind the ApplicationController's default
#     sign-in gate (and the email-verification wall) — the map page is an
#     authenticated surface, unlike the /c/:token share.
#   * #own_routes reads ONLY current_user's routes (private included, §4.1);
#     no other user's row can enter the payload by construction.
#   * #public_routes selects other users' routes exclusively through
#     Route.publicly_visible — the Phase 9 share rules (owner's calendar is
#     public AND the route is scheduled on it) enforced in SQL, independent
#     of the GPX-Studio signed-id URL trick (§4.2: an unguessable URL never
#     makes a route public). Private routes of other users have no path
#     into this response.
class MapsController < ApplicationController
  # §5: never return the full global public collection. One extra row is
  # fetched so the response can flag truncation without a COUNT.
  VIEWPORT_LIMIT = 500
  # Ceiling on the exclude_ids delta payload (see #set_excluded_route_ids)
  # so a long-roaming session can't grow the request URL without bound.
  MAX_EXCLUDED_IDS = 1_000

  # 400 copy for a rejected filter set. Built from the category keys so the
  # accepted values can never drift from the validator below.
  INVALID_FILTERS_ERROR = "Invalid filters: sport_type must be one of " \
                          "#{Map::RouteFinder::SPORT_PATTERNS.keys.join(', ')} " \
                          "or all; distance/elevation/duration bounds must be " \
                          "non-negative numbers with min <= max.".freeze

  # Validates west/south/east/north into @bounds before the viewport queries
  # run (own and public alike, §5.1); malformed requests are answered with a
  # 400 JSON error. The explicit `return false` after rendering halts the
  # before_action chain rather than relying on the implicit render-halts
  # semantics (two validators run for #recommendations, and a silent
  # continuation would run the action with @bounds == nil).
  before_action :set_viewport_bounds, only: %i[own_routes public_routes recommendations]
  # Delta loading: ids the client already merged (comma-separated in
  # exclude_ids) never need to ship again — validated with the same
  # 400-on-garbage contract as the bounds. Shared by both feeds: the client
  # caches each by id and re-requests only what it is still missing.
  before_action :set_excluded_route_ids, only: %i[own_routes public_routes]
  # "Find new routes" filters (sport category, distance/elevation/duration
  # bounds): whitelisted and numerically validated before the recommendation
  # queries run — garbage answers 400 JSON exactly like malformed bounds.
  before_action :set_recommendation_filters, only: %i[recommendations]

  def show
    # The sub-bar's "My Routes" pill seeds server-side; the map counts
    # arrive with the viewport fetches (client-side).
    @own_route_count = current_user.routes.count
    # The most-ridden place (§3.1/§3.2) must be computed here: own routes
    # load per viewport now, so the browser never holds the full library a
    # client-side hotspot scan would need.
    @own_hotspot_bounds = Map::OwnRoutesHotspot.bounds(current_user.routes)
  end

  # GET /map/routes/own?west=&south=&east=&north= — routes of the current
  # user whose bounding box intersects the viewport (§5.1), delta-loaded like
  # the public feed: exclude_ids keeps already-merged routes from shipping
  # again, and the client skips viewports it has already fetched. No cap and
  # no min zoom — the library is the viewer's own (§4.1). Both attachments
  # preload: the cache key needs the GPX blob and the drawer thumb needs the
  # static-map blob (one SELECT per table).
  def own_routes
    scope = viewport_scope(current_user.routes)
    scope = scope.where.not(id: @excluded_ids) if @excluded_ids.any?

    render json: Map::RouteFeature.collection(scope, own: true, public_ids: own_public_route_ids(scope))
  end

  # GET /map/routes/public?west=&south=&east=&north= — other users' public
  # routes whose bounding box intersects the viewport (§5.1). Own routes are
  # excluded: they are already fully loaded via #own_routes and must never
  # be double-drawn. Most-recently-touched routes win the limit.
  def public_routes
    scope = viewport_scope(Route.publicly_visible.where.not(user_id: current_user.id))
    # Delta loading: routes the client already merged never ship again —
    # the response carries only what the map is still missing.
    scope = scope.where.not(id: @excluded_ids) if @excluded_ids.any?

    routes = scope.limit(VIEWPORT_LIMIT + 1).to_a
    payload = Map::RouteFeature.collection(routes.first(VIEWPORT_LIMIT), own: false)
    # Post-exclusion semantics: the flag now means more routes the client
    # hasn't loaded yet intersect this viewport than the cap — the status
    # pill answers it with "zoom in to load more".
    payload["truncated"] = routes.size > VIEWPORT_LIMIT
    render json: payload
  end

  # GET /map/routes/recommendations?west=&south=&east=&north=&sport_type=&
  # distance_min=&distance_max=&elevation_max=&duration_min=&duration_max= —
  # "Find new routes" (design-refs/stitch_explorer_v0.14): routes matching
  # the active filters inside the viewport. The viewer's own routes ship
  # FIRST (private included, §4.1 — the drawer lists them before the public
  # matches), then other users' public routes under the Phase 9 SQL
  # contract, capped at VIEWPORT_LIMIT with a truncated flag. No
  # exclude_ids delta here: the match set changes with every filter change,
  # so the client always needs the honest, complete list (drawer count +
  # filter chips must agree with what is drawn).
  def recommendations
    public_routes = filtered_viewport_routes(
      Route.publicly_visible.where.not(user_id: current_user.id),
    ).limit(VIEWPORT_LIMIT + 1).to_a

    own_scope = filtered_viewport_routes(current_user.routes)
    features =
      Map::RouteFeature.collection(
        own_scope, own: true, public_ids: own_public_route_ids(own_scope)
      )["features"] +
      Map::RouteFeature.collection(
        public_routes.first(VIEWPORT_LIMIT), own: false
      )["features"]

    render json: {
      type: "FeatureCollection",
      features: features,
      truncated: public_routes.size > VIEWPORT_LIMIT
    }
  end

  # GET /map/place_label?lon=&lat= — reverse-geocoded "City, Region, Country"
  # for the sub-bar location chip (Photon via Map::ReverseGeocoder, cached
  # per ~1 km cell server-side). Malformed coordinates answer 400 JSON like
  # the viewport params; an upstream failure renders a null place_label the
  # client treats as "keep the current label".
  def place_label
    lon = Float(params[:lon])
    lat = Float(params[:lat])
    finite = [ lon, lat ].all?(&:finite?)
    valid = finite && lat.between?(-90, 90) && lon.between?(-360, 360)
    raise ArgumentError unless valid

    # Same wrap rationale as the viewport lons above: MapLibre may hand back
    # values past ±180, Photon wants [-180, 180].
    lon = ((lon + 180.0) % 360.0) - 180.0
    render json: { place_label: Map::ReverseGeocoder.label(lon, lat) }
  rescue ArgumentError, TypeError
    render json: { error: "Invalid coordinates: expected numeric lon and lat with lat in [-90, 90]." },
           status: :bad_request
  end

  private

  # Route ids of mine that are publicly viewable right now — one distinct
  # query over my calendar entries, gated on my own calendar being public
  # (the same contract as Route#publicly_viewable?, batched).
  def own_public_route_ids(routes)
    return [] unless current_user.calendar_public?

    current_user.calendar_entries
                .where(route_id: routes)
                .distinct.pluck(:route_id)
  end

  # One filtered viewport query for the finder: bounding-box intersection
  # (§5.1), the attachment preloads the feature builder shares with the
  # other two feeds, most-recently-touched first, and the active find
  # filters applied by Map::RouteFinder (filter semantics live in exactly
  # one place so counts and chips agree with the drawn lines).
  def filtered_viewport_routes(scope)
    Map::RouteFinder.call(viewport_scope(scope), filters: @recommendation_filters)
  end

  # The shared viewport read for all three GeoJSON feeds (#10): only routes
  # the map can draw (with_track), intersecting the requested rect (§5.1),
  # with both attachments preloaded — the cache key needs the GPX blob and
  # the drawer thumb needs the static-map blob (one SELECT per table) — and
  # most-recently-touched first. Keeping this in one place means the feeds
  # cannot drift apart in eager-loading or ordering.
  def viewport_scope(scope)
    scope.with_track
         .intersecting_viewport(*@bounds)
         .includes(gpx_file_attachment: :blob, static_map_attachment: :blob)
         .order(updated_at: :desc)
  end


  # Whitelist + validate the "Find new routes" filter params before
  # #recommendations runs: unknown sport categories and non-numeric or
  # nonsensical bounds answer 400 exactly like malformed viewport bounds
  # (§9). Absent params mean "open" — the client omits the value at slider
  # ends ("180+ km", "3,000+ m") and for an all-passing sport ("all").
  # Validated values land in @recommendation_filters for Map::RouteFinder.
  def set_recommendation_filters
    sport = params[:sport_type]
    if sport.present? && sport != "all" &&
       !Map::RouteFinder::SPORT_PATTERNS.key?(sport)
      raise ArgumentError, "unknown sport_type"
    end

    distance_min = non_negative_number(params[:distance_min])
    distance_max = non_negative_number(params[:distance_max])
    if distance_min && distance_max && distance_min > distance_max
      raise ArgumentError, "distance_min above distance_max"
    end

    duration_min = non_negative_number(params[:duration_min])
    duration_max = non_negative_number(params[:duration_max])
    if duration_min && duration_max && duration_min > duration_max
      raise ArgumentError, "duration_min above duration_max"
    end

    sport_type = sport.presence if sport != "all"

    @recommendation_filters = {
      sport_type: sport_type,
      distance_min: distance_min,
      distance_max: distance_max,
      elevation_max: non_negative_number(params[:elevation_max]),
      duration_min: duration_min,
      duration_max: duration_max
    }.compact
  rescue ArgumentError, TypeError
    render json: { error: INVALID_FILTERS_ERROR }, status: :bad_request
    false
  end

  # A validated float ≥ 0, or nil for absent/blank params. Garbage raises
  # ArgumentError (caught by the caller → 400), exactly like Float() on the
  # viewport bounds above.
  def non_negative_number(raw)
    return if raw.blank?

    value = Float(raw)
    raise ArgumentError, "not a non-negative number" unless value.finite? && value >= 0

    value
  end

  # Parse + validate the viewport params before #public_routes runs (§9:
  # handle invalid bounds). Lons are accepted in [-360, 360] because
  # MapLibre may hand back wrap-normalized values past ±180; anything else
  # malformed answers 400 with a JSON error the client surfaces in its
  # status pill.
  def set_viewport_bounds
    west = Float(params[:west])
    south = Float(params[:south])
    east = Float(params[:east])
    north = Float(params[:north])
    finite = [ west, south, east, north ].all?(&:finite?)
    valid = finite && south < north && south >= -90 && north <= 90 &&
             west.between?(-360, 360) && east.between?(-360, 360) && west != east
    raise ArgumentError unless valid

    @bounds = [ west, south, east, north ]
  rescue ArgumentError, TypeError
    render json: { error: "Invalid viewport: expected numeric west, south, east, north with south < north." },
           status: :bad_request
    false
  end

  # Delta loading (§5.1/§5.2: "avoid duplicate requests"): the map client
  # merges every response by id and re-sends what it already holds as
  # comma-separated exclude_ids, so the viewport payload ships only routes
  # the client doesn't have. Unknown ids simply match no rows; anything
  # non-numeric answers 400 exactly like malformed bounds.
  def set_excluded_route_ids
    tokens = params[:exclude_ids].to_s.split(",").reject(&:blank?)
    raise ArgumentError if tokens.size > MAX_EXCLUDED_IDS

    @excluded_ids = tokens.map { |token| Integer(token, 10) }
  rescue ArgumentError, TypeError
    render json: { error: "Invalid exclude_ids: expected comma-separated numeric route ids." },
           status: :bad_request
    false
  end
end
