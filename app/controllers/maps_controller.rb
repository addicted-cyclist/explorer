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

  # Validates west/south/east/north into @bounds before the viewport query
  # runs; malformed requests are answered with a 400 JSON error.
  before_action :set_viewport_bounds, only: :public_routes
  # Delta loading: ids the client already merged (comma-separated in
  # exclude_ids) never need to ship again — validated with the same
  # 400-on-garbage contract as the bounds.
  before_action :set_excluded_route_ids, only: :public_routes

  def show
    # The sub-bar's "My Routes" pill seeds server-side; the public count
    # arrives with the first viewport fetch (client-side).
    @own_route_count = current_user.routes.count
  end

  # GET /map/routes/own — every route of the current user, viewport-
  # independent so own tracks stay visible even outside the current view
  # (§5.1). Both attachments preload: the cache key needs the GPX blob and
  # the drawer thumb needs the static-map blob (one SELECT per table).
  def own_routes
    routes = current_user.routes
                          .includes(gpx_file_attachment: :blob, static_map_attachment: :blob)
    render json: Map::RouteFeature.collection(routes, own: true, public_ids: own_public_route_ids(routes))
  end

  # GET /map/routes/public?west=&south=&east=&north= — other users' public
  # routes whose bounding box intersects the viewport (§5.1). Own routes are
  # excluded: they are already fully loaded via #own_routes and must never
  # be double-drawn. Most-recently-touched routes win the limit.
  def public_routes
    scope = Route.publicly_visible
                 .where.not(user_id: current_user.id)
                 .with_track
                 .intersecting_viewport(*@bounds)
                 .includes(gpx_file_attachment: :blob, static_map_attachment: :blob)
                 .order(updated_at: :desc)
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
  end

  # Delta loading (§5.2: "avoid duplicate requests"): the map client merges
  # every public response by id and re-sends what it already holds as
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
  end
end
