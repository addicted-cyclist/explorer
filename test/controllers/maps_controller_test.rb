# frozen_string_literal: true

require "test_helper"

# The My Map page and its two GeoJSON endpoints (technote.MYMAP-FEATURE.md
# §4/§5). The suite pins the authorization contract: own routes are always
# the viewer's (private included), and the public query returns ONLY routes
# that are publicly viewable under the Phase 9 rules (owner's calendar share
# live + scheduled) intersecting the requested viewport.
class MapsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @viewer = User.create!(valid_user_attributes)
    sign_in @viewer

    @public_owner = User.create!(valid_user_attributes(email: "public@example.com", username: "public_rider"))
    @public_owner.update!(calendar_public: true)
    @public_route = tracked_route(@public_owner, "Public coastal loop")
    # Public visibility (Phase 9) = live share + the ride scheduled on the
    # owner's own calendar — give the fixture route its entry.
    @public_owner.calendar_entries.create!(route: @public_route, scheduled_on: Date.current + 1,
                                           start_time: "08:00", end_time: "10:00")
    @hidden_library_route = @public_owner.routes.create!(source: "upload", title: "Unscheduled ride")
    attach_track(@hidden_library_route)

    @private_owner = User.create!(valid_user_attributes(email: "private@example.com", username: "shy_rider"))
    @private_route = tracked_route(@private_owner, "Secret alpine pass")

    @own_route = tracked_route(@viewer, "My Zurich loop")
  end

  # ---- page ----------------------------------------------------------------

  test "the map page requires sign-in" do
    sign_out @viewer

    get map_path
    assert_redirected_to new_user_session_path
  end

  test "the map page renders with the map workspace and nav highlighting" do
    get map_path

    assert_response :success
    assert_select "div[data-controller=\"my-map\"]"
    assert_select "nav.app-nav a.app-nav__link--active", text: "My Map"
    # The most-ridden place ships server-side (own routes load per viewport,
    # so the client can no longer derive it) — the fixture ride's box here.
    expected = Map::OwnRoutesHotspot.bounds(@viewer.routes)
    assert_match "data-my-map-hotspot-bounds-value=\"#{expected.to_json}\"",
                 response.body
  end

  test "the map page ships an empty hotspot when no route is parsed yet" do
    @viewer.routes.destroy_all

    get map_path

    assert_response :success
    assert_match 'data-my-map-hotspot-bounds-value="[]"', response.body
  end

  # The sport categories have exactly one definition (Map::RouteFinder::
  # SPORT_CATEGORIES). These tests pin the three consumers to it, so adding a
  # category server-side cannot silently leave the modal or the chips behind.
  test "the find modal's sport buttons come from SPORT_CATEGORIES" do
    get map_path

    assert_response :success
    # "all" is the leading UI-only button; the rest are the real categories.
    rendered = css_select(".find-routes__segment-btn").map { |node| node["data-sport"] }
    assert_equal [ "all", *Map::RouteFinder::SPORT_PATTERNS.keys ], rendered
  end

  test "the find modal's sport buttons carry the SPORT_CATEGORIES labels" do
    get map_path

    Map::RouteFinder::SPORT_CATEGORIES.each do |key, category|
      assert_select ".find-routes__segment-btn[data-sport='#{key}']", text: category[:label]
    end
  end

  test "the drawer chips receive the sport categories as a Stimulus value" do
    get map_path

    expected = Map::RouteFinder::SPORT_CATEGORIES.map do |key, category|
      { key: key, label: category[:label] }
    end
    assert_match "data-my-map-sports-value=\"#{ERB::Util.html_escape(expected.to_json)}\"",
                 response.body
  end

  # ---- own routes (§4.1/§5.1) ------------------------------------------------

  test "own routes returns the viewer's viewport rides, private included" do
    get own_map_routes_path, params: viewport, headers: { Accept: "application/json" }

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal "FeatureCollection", payload["type"]
    assert_equal 1, payload["features"].size

    properties = payload["features"].first["properties"]
    assert_equal @own_route.id, properties["id"]
    assert_equal "My Zurich loop", properties["title"]
    assert_equal true, properties["own"]
    assert_equal route_path(@own_route), properties["url"]
  end

  test "own routes never includes anyone else's routes" do
    get own_map_routes_path, params: viewport, headers: { Accept: "application/json" }

    payload = JSON.parse(response.body)
    ids = payload["features"].map { |feature| feature["properties"]["id"] }
    assert_not_includes ids, @public_route.id
    assert_not_includes ids, @private_route.id
    assert_not_includes ids, @hidden_library_route.id
  end

  test "own routes skips rides outside the requested viewport" do
    get own_map_routes_path,
        params: { west: "0.0", south: "10.0", east: "1.0", north: "11.0" },
        headers: { Accept: "application/json" }

    payload = JSON.parse(response.body)
    assert_equal "FeatureCollection", payload["type"]
    assert_empty payload["features"]
  end

  test "own routes requires sign-in" do
    sign_out @viewer

    get own_map_routes_path, params: viewport
    assert_redirected_to new_user_session_path
  end

  test "own routes answers 400 for malformed bounds" do
    get own_map_routes_path,
        params: { west: "not-a-number", south: "47.0", east: "9.0", north: "48.0" },
        headers: { Accept: "application/json" }

    assert_response :bad_request
    assert JSON.parse(response.body)["error"].present?
  end

  test "own routes omits routes the client already loaded (delta loading)" do
    second = tracked_route(@viewer, "Second own ride")

    get own_map_routes_path,
        params: viewport.merge(exclude_ids: @own_route.id.to_s),
        headers: { Accept: "application/json" }

    assert_response :success
    ids = JSON.parse(response.body)["features"].map { |feature| feature["properties"]["id"] }
    assert_not_includes ids, @own_route.id
    assert_includes ids, second.id
  end

  test "own routes flags which of the viewer's rides are publicly scheduled" do
    @viewer.update!(calendar_public: true)
    @viewer.calendar_entries.create!(route: @own_route, scheduled_on: Date.current + 1,
                                     start_time: "08:00", end_time: "10:00")

    get own_map_routes_path, params: viewport, headers: { Accept: "application/json" }

    properties = JSON.parse(response.body)["features"].first["properties"]
    assert_equal true, properties["public"]
  end

  # ---- public routes (§4.2/§5.1) --------------------------------------------

  test "public routes returns other users' public rides intersecting the viewport" do
    get public_map_routes_path, params: viewport, headers: { Accept: "application/json" }

    assert_response :success
    payload = JSON.parse(response.body)
    ids = payload["features"].map { |feature| feature["properties"]["id"] }

    assert_includes ids, @public_route.id
    # Phase 9 visibility contract in SQL: unscheduled library rides and
    # private-calendar owners stay invisible even inside the viewport.
    assert_not_includes ids, @hidden_library_route.id
    assert_not_includes ids, @private_route.id
    assert payload["features"].all? { |feature| feature["properties"]["own"] == false }
  end

  test "public routes excludes the viewer's own public ride (it ships via own routes)" do
    @viewer.update!(calendar_public: true)
    @viewer.calendar_entries.create!(route: @own_route, scheduled_on: Date.current + 1,
                                     start_time: "08:00", end_time: "10:00")

    get public_map_routes_path, params: viewport, headers: { Accept: "application/json" }

    ids = JSON.parse(response.body)["features"].map { |feature| feature["properties"]["id"] }
    assert_not_includes ids, @own_route.id
  end

  test "public routes skips rides outside the requested viewport" do
    get public_map_routes_path, params: {
      west: "0.0", south: "10.0", east: "1.0", north: "11.0"
    }, headers: { Accept: "application/json" }

    payload = JSON.parse(response.body)
    assert_equal "FeatureCollection", payload["type"]
    assert_empty payload["features"]
  end

  test "public routes requires sign-in" do
    sign_out @viewer

    get public_map_routes_path, params: viewport
    assert_redirected_to new_user_session_path
  end

  test "public routes answers 400 for malformed bounds" do
    get public_map_routes_path, params: {
      west: "not-a-number", south: "47.0", east: "9.0", north: "48.0"
    }, headers: { Accept: "application/json" }

    assert_response :bad_request
    assert JSON.parse(response.body)["error"].present?
  end

  test "public routes answers 400 for inverted latitude bounds" do
    get public_map_routes_path, params: {
      west: "8.0", south: "48.0", east: "9.0", north: "47.0"
    }, headers: { Accept: "application/json" }

    assert_response :bad_request
  end

  # ---- delta loading (exclude_ids) --------------------------------------------

  test "public routes omits routes the client already loaded" do
    other = tracked_route(@public_owner, "Second public climb")
    @public_owner.calendar_entries.create!(route: other, scheduled_on: Date.current + 2,
                                           start_time: "08:00", end_time: "10:00")

    get public_map_routes_path,
        params: viewport.merge(exclude_ids: @public_route.id.to_s),
        headers: { Accept: "application/json" }

    assert_response :success
    ids = JSON.parse(response.body)["features"].map { |feature| feature["properties"]["id"] }
    assert_not_includes ids, @public_route.id
    assert_includes ids, other.id
    # Exclusion never widens visibility: the Phase 9 rules still hide the
    # unscheduled library ride and the private owner's track.
    assert_not_includes ids, @hidden_library_route.id
    assert_not_includes ids, @private_route.id
  end

  test "public routes ignores exclude_ids matching nothing" do
    get public_map_routes_path,
        params: viewport.merge(exclude_ids: "99999999"),
        headers: { Accept: "application/json" }

    assert_response :success
    ids = JSON.parse(response.body)["features"].map { |feature| feature["properties"]["id"] }
    assert_includes ids, @public_route.id
  end

  test "public routes answers 400 for malformed exclude_ids" do
    get public_map_routes_path,
        params: viewport.merge(exclude_ids: "1,not-an-id"),
        headers: { Accept: "application/json" }

    assert_response :bad_request
    assert JSON.parse(response.body)["error"].present?
  end

  # ---- recommendations (find new routes) --------------------------------------

  test "recommendations requires sign-in" do
    sign_out @viewer

    get recommendations_map_routes_path, params: viewport
    assert_redirected_to new_user_session_path
  end

  test "recommendations lists the viewer's routes first, then public routes" do
    get recommendations_map_routes_path, params: viewport, headers: { Accept: "application/json" }

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal "FeatureCollection", payload["type"]
    ids = payload["features"].map { |feature| feature["properties"]["id"] }
    # Own first (private included), other users' public routes after.
    assert_equal [ @own_route.id, @public_route.id ], ids
    assert_equal true, payload["features"].first["properties"]["own"]
    assert_equal false, payload["features"].second["properties"]["own"]
  end

  test "recommendations keeps other users' private and unscheduled routes out" do
    get recommendations_map_routes_path, params: viewport, headers: { Accept: "application/json" }

    ids = JSON.parse(response.body)["features"].map { |feature| feature["properties"]["id"] }
    assert_not_includes ids, @hidden_library_route.id
    assert_not_includes ids, @private_route.id
  end

  test "recommendations applies the sport category filter" do
    @own_route.update!(sport_type: "Mountain biking")
    @public_route.update!(sport_type: "Road Cycling")

    get recommendations_map_routes_path,
        params: viewport.merge(sport_type: "road"), headers: { Accept: "application/json" }

    ids = JSON.parse(response.body)["features"].map { |feature| feature["properties"]["id"] }
    assert_equal [ @public_route.id ], ids
  end

  # End-to-end regression for the reported mismatch: routes whose sport_type
  # is blank display as "Road bike" everywhere in the UI, so the Road filter
  # must return them instead of hiding them behind a badge that claims
  # otherwise.
  test "recommendations treats blank sport_type as a road match, like its badge" do
    @own_route.update!(sport_type: nil)
    @public_route.update!(sport_type: "")
    other = @public_owner.routes.create!(source: "upload", title: "Gravel loop",
                                        sport_type: "Gravel")
    attach_track(other)
    @public_owner.calendar_entries.create!(route: other, scheduled_on: Date.current + 2,
                                           start_time: "08:00", end_time: "10:00")

    get recommendations_map_routes_path,
        params: viewport.merge(sport_type: "road"), headers: { Accept: "application/json" }

    ids = JSON.parse(response.body)["features"].map { |feature| feature["properties"]["id"] }
    assert_includes ids, @own_route.id
    assert_includes ids, @public_route.id
    assert_not_includes ids, other.id
  end

  test "recommendations applies distance bounds and drops unmeasured routes" do
    @own_route.update!(distance: 48.4)
    @public_route.update!(distance: 92.0)

    get recommendations_map_routes_path,
        params: viewport.merge(distance_min: "50", distance_max: "100"),
        headers: { Accept: "application/json" }

    ids = JSON.parse(response.body)["features"].map { |feature| feature["properties"]["id"] }
    assert_equal [ @public_route.id ], ids
  end

  test "recommendations applies the elevation gain cap" do
    @own_route.update!(elevation_gain: 820.0)
    @public_route.update!(elevation_gain: 1500.0)

    get recommendations_map_routes_path,
        params: viewport.merge(elevation_max: "1000"),
        headers: { Accept: "application/json" }

    ids = JSON.parse(response.body)["features"].map { |feature| feature["properties"]["id"] }
    assert_equal [ @own_route.id ], ids
  end

  test "recommendations applies the duration range in seconds" do
    @own_route.update!(duration: 7200)
    @public_route.update!(duration: 14_400)

    get recommendations_map_routes_path,
        params: viewport.merge(duration_min: "3600", duration_max: "10800"),
        headers: { Accept: "application/json" }

    ids = JSON.parse(response.body)["features"].map { |feature| feature["properties"]["id"] }
    assert_equal [ @own_route.id ], ids
  end

  # #7: the truncation flag is what tells the drawer "zoom in to load more",
  # so it must flip only when more matches exist than the cap ships.
  test "recommendations flags truncation when matches exceed the cap" do
    # Every route must be publicly visible (Phase 9: live share + scheduled on
    # the owner's own calendar) or it never enters the public match set.
    (MapsController::VIEWPORT_LIMIT + 1).times do |i|
      route = @public_owner.routes.create!(source: "upload", title: "Public #{i}")
      attach_track(route)
      @public_owner.calendar_entries.create!(route: route, scheduled_on: Date.current + 3,
                                             start_time: "08:00", end_time: "10:00")
    end

    get recommendations_map_routes_path, params: viewport, headers: { Accept: "application/json" }

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal true, payload["truncated"]
    assert_equal MapsController::VIEWPORT_LIMIT,
                 payload["features"].count { |feature| !feature["properties"]["own"] }
  end

  # #7: an own route that is publicly viewable must keep its public flag when
  # it arrives through the FILTERED relation (own_public_route_ids runs on the
  # filtered scope, not the whole library).
  test "recommendations marks own publicly viewable matches as public" do
    @viewer.update!(calendar_public: true)
    @viewer.calendar_entries.create!(route: @own_route, scheduled_on: Date.current + 1,
                                     start_time: "08:00", end_time: "10:00")

    get recommendations_map_routes_path,
        params: viewport.merge(sport_type: "road"), headers: { Accept: "application/json" }

    feature = JSON.parse(response.body)["features"].find { |f| f["properties"]["own"] }
    assert feature, "expected the viewer's own route to match the road filter"
    assert_equal true, feature["properties"]["public"]
  end

  # #7: "all" is the client's way of saying "no sport constraint"; the
  # controller accepts it explicitly and it must behave like an absent param.
  test "recommendations treats sport_type=all as no sport constraint" do
    @own_route.update!(sport_type: "Mountain biking")
    @public_route.update!(sport_type: "Gravel")

    get recommendations_map_routes_path,
        params: viewport.merge(sport_type: "all"), headers: { Accept: "application/json" }

    ids = JSON.parse(response.body)["features"].map { |f| f["properties"]["id"] }
    assert_includes ids, @own_route.id
    assert_includes ids, @public_route.id
  end

  test "recommendations answers 400 for malformed filters" do
    get recommendations_map_routes_path,
        params: viewport.merge(distance_min: "soon"), headers: { Accept: "application/json" }
    assert_response :bad_request
    assert JSON.parse(response.body)["error"].present?

    get recommendations_map_routes_path,
        params: viewport.merge(sport_type: "underwater"), headers: { Accept: "application/json" }
    assert_response :bad_request

    get recommendations_map_routes_path,
        params: viewport.merge(distance_min: "100", distance_max: "10"),
        headers: { Accept: "application/json" }
    assert_response :bad_request

    get recommendations_map_routes_path,
        params: viewport.merge(duration_min: "-5"), headers: { Accept: "application/json" }
    assert_response :bad_request
  end

  test "recommendations answers 400 for malformed viewport bounds" do
    get recommendations_map_routes_path,
        params: viewport.merge(north: "not-a-number"), headers: { Accept: "application/json" }

    assert_response :bad_request
    assert JSON.parse(response.body)["error"].present?
  end

  # ---- place label (location chip) -------------------------------------------

  test "place label requires sign-in" do
    sign_out @viewer

    get map_place_label_path, params: { lon: "108.2022", lat: "16.0544" }
    assert_redirected_to new_user_session_path
  end

  test "place label returns the reverse-geocoded label" do
    with_label_result("Da Nang, Vietnam") do
      get map_place_label_path, params: { lon: "108.2022", lat: "16.0544" }
    end

    assert_response :success
    assert_equal({ "place_label" => "Da Nang, Vietnam" }, JSON.parse(response.body))
  end

  test "place label renders a null label when the geocoder has no answer" do
    with_label_result(nil) do
      get map_place_label_path, params: { lon: "108.2022", lat: "16.0544" }
    end

    assert_response :success
    assert_equal({ "place_label" => nil }, JSON.parse(response.body))
  end

  test "place label normalizes lons past ±180 (MapLibre wrap) before geocoding" do
    received = []
    with_label_result(->(lon, lat) { received << [ lon, lat ]; "Somewhere" }) do
      get map_place_label_path, params: { lon: "190", lat: "16.05" }
    end

    assert_response :success
    assert_equal [ [ -170.0, 16.05 ] ], received
  end

  test "place label answers 400 for malformed coordinates" do
    get map_place_label_path, params: { lon: "not-a-number", lat: "16.05" }
    assert_response :bad_request

    get map_place_label_path, params: { lon: "108.2", lat: "95" }
    assert_response :bad_request

    get map_place_label_path, params: { lon: "108.2", lat: "NaN" }
    assert_response :bad_request

    get map_place_label_path, params: { lat: "16.05" }
    assert_response :bad_request
  end

  private

  # No mocha in this app — swap Map::ReverseGeocoder.label for the duration
  # of +block+ and always restore the original method. +result+ may be a
  # value or a callable receiving (lon, lat).
  def with_label_result(result, &block)
    original = Map::ReverseGeocoder.singleton_method(:label)
    Map::ReverseGeocoder.define_singleton_method(:label) do |lon, lat|
      result.respond_to?(:call) ? result.call(lon, lat) : result
    end
    block.call
  ensure
    Map::ReverseGeocoder.define_singleton_method(:label, original)
  end

  def viewport
    # Zurich-area box covering the exploration.gpx fixture track.
    { west: "8.0", south: "47.0", east: "9.0", north: "48.0" }
  end

  # A route with an attached, parsed GPX (bounds captured by the parse).
  def tracked_route(owner, title)
    route = owner.routes.create!(source: "upload", title: title)
    attach_track(route)
    route
  end

  def attach_track(route)
    route.gpx_file.attach(gpx_fixture_upload("exploration.gpx"))
    route.parse_gpx!
  end

  # ---- Route Planner edit entry (technote.ROUTE-DRAW.md §2.2) ----------------

  test "map?edit=ID boots the planner with the route's server-rendered state" do
    route = tracked_route(@viewer, "Editable gravel loop")
    route.update!(routing_profile: "gravel", planner_geometry: {
      "loop" => true,
      "segments" => [ { "points" => [ [ 8.0, 47.0, 100.0 ], [ 8.01, 47.01, 110.0 ], [ 8.0, 47.0, 100.0 ] ] } ]
    })
    route.routing_waypoints.create!(position: 0, lat: 47.0, lon: 8.0)
    route.routing_waypoints.create!(position: 1, lat: 47.01, lon: 8.01)

    get map_path(edit: route.id)

    assert_response :success
    root = css_select('div[data-controller="my-map"]').first
    state = JSON.parse(root["data-my-map-edit-state-value"])
    assert_equal route.id, state["route_id"]
    assert_equal "Editable gravel loop", state["title"]
    assert_equal "gravel", state["profile"]
    assert state["loop"]
    assert_equal 2, state["waypoints"].size
    assert_equal 1, state["segments"].size
  end

  test "map without edit ships an empty planner state" do
    get map_path

    assert_response :success
    root = css_select('div[data-controller="my-map"]').first
    assert_equal({}, JSON.parse(root["data-my-map-edit-state-value"]))
  end

  test "another user's route never opens in the editor (even a public one)" do
    get map_path(edit: @public_route.id)

    assert_redirected_to map_path
  end

  test "a bogus edit id redirects back to the plain map" do
    get map_path(edit: "99999999")

    assert_redirected_to map_path
  end

  test "the draw button is live and the planner panel ships with the page" do
    get map_path

    assert_response :success
    assert_select "button[data-action=\"my-map#enterPlanner\"]"
    assert_select "aside[data-my-map-target=\"plannerPanel\"]"
    assert_select "form[data-planner=\"poi-form\"]"
    assert_select "[data-my-map-planner-calculate-url-value]"
    assert_select "[data-my-map-planner-save-url-value]"
    assert_select "[data-my-map-planner-poi-image-url-value]"
  end

  # The route_planner module binds to data-planner hooks by key; a renamed or
  # missing hook in the ERB makes entering the planner throw inside the click
  # action (undefined.addEventListener). This test derives the required hooks
  # FROM the module source, so the view/JS contract cannot silently drift.
  test "the page ships every DOM hook the route_planner module binds to" do
    get map_path

    assert_response :success
    source = Rails.root.join("app/javascript/map/route_planner.js").read

    kebab_hooks = source.scan(/this\.dom\[["']([a-z-]+)["']\]/).flatten
    camel_hooks = source.scan(/this\.dom\.([a-zA-Z]+)/).flatten
                        .map { |name| name.gsub(/([a-z\d])([A-Z])/) { "#{Regexp.last_match(1)}-#{Regexp.last_match(2).downcase}" } }
                        # "profiles" is a synthetic collectDom key (the profile
                        # button group), not a data-planner attribute.
                        .reject { |key| key == "profiles" }

    hooks = (kebab_hooks + camel_hooks).uniq.sort
    assert hooks.include?("waypoint-list"), "the scanner must find the module's hook accesses"
    hooks.each do |hook|
      assert_includes response.body, %(data-planner="#{hook}"),
                      "the planner module binds to data-planner=\"#{hook}\" but the page does not ship it"
    end
  end

  # Re-entering the planner (Exit → "Draw new route") must not stack handlers
  # or re-add sources: MapLibre throws "Source already exists" and a single
  # segment drag would fire one recalculation per stacked listener. Sources
  # survive teardown, so addMapLayers is idempotent and every this.map.on
  # (plus the document keydown) is matched by a detach in teardown().
  test "the planner module detaches every handler and re-adds its map layers safely" do
    source = Rails.root.join("app/javascript/map/route_planner.js").read
    setup_body = source[/addMapLayers\(\) \{.*?\n  \}/m].to_s
    teardown_body = source[/teardown\(\) \{.*?\n  \}/m].to_s
    assert_not_empty setup_body, "could not locate addMapLayers()"
    assert_not_empty teardown_body, "could not locate teardown()"

    assert_includes setup_body, 'getSource("planner-route")',
                    "addMapLayers must not re-add an existing source (re-entry throws __map.addSource: Source already exists)"
    assert_includes setup_body, "getLayer(definition.id)",
                    "addMapLayers must not re-add an existing layer"

    events = setup_body.scan(/this\.map\.on\(\s*["'](\w+)["']/).flatten
    assert_includes events, "mousedown", "the scanner must find the layer-scoped mousedown binding"
    assert_includes events, "click"
    events.uniq.each do |event|
      assert_includes teardown_body, "map.off(\"#{event}\"",
                      "teardown() never detaches the map's #{event} handler — re-entry stacks a second one"
    end
    # A handler bound inline (anonymous arrow) can never be detached: teardown
    # would need its identity. Every planner map handler must be stored on the
    # instance (`this.xxxHandler = ...`) and passed by that name to map.off.
    stored = setup_body.scan(/this\.(\w+Handler) = /).flatten
    assert_includes stored, "hitDownHandler", "the layer-scoped mousedown handler must be stored for teardown"
    assert_includes stored, "hitEnterHandler"
    assert_includes stored, "hitLeaveHandler"
    stored.each do |handler|
      assert_includes teardown_body, "this.#{handler}",
                      "teardown() does not detach #{handler} — it is bound but never removed"
    end
    assert_nil setup_body[/this\.map\.on\(\s*["'](?:mousedown|mouseenter|mouseleave)["'][^\n]*\(\)\s*=>/],
               "layer-scoped planner handlers must be named on the instance, not bound inline"

    assert_includes source[/bindDom\(\) \{.*?\n  \}/m].to_s, "document.addEventListener"
    assert_includes teardown_body, "document.removeEventListener"
  end

  # Regression: /map?edit=ID and the popup's Edit link reloaded into a plain
  # map. onMapLoad added the browsing sources/layers BEFORE booting the
  # planner; those pending style mutations make isStyleLoaded() answer false
  # even inside the "load" event, so startPlanner parked the editor state with
  # its only retry hook ("load") already running — the editor never opened.
  # The boot must precede the layer mutations, and a parked state must get a
  # live retry (once("idle")) so it can never strand.
  test "the planner edit boot precedes style mutations and parked state retries on idle" do
    source = Rails.root.join("app/javascript/controllers/my_map_controller.js").read
    load_body = source[/onMapLoad\(\) \{.*?\n  \}/m].to_s
    assert_not_empty load_body, "could not locate onMapLoad()"

    boot_index = [ load_body.index("enterPlannerFromEditState"),
                   load_body.index("this.startPlanner") ].compact.min
    layers_index = load_body.index("this.addRouteLayers")
    assert boot_index && layers_index, "onMapLoad must boot the planner and add the route layers"
    assert_operator boot_index, :<, layers_index,
                   "the planner must boot BEFORE addRouteLayers — pending source updates flip isStyleLoaded() and strand the edit boot"
    assert_includes load_body, "pendingPlannerState",
                    "a state parked by a Draw press before load must be consumed on load"

    start_body = source[/startPlanner\(initialState\) \{.*?\n  \}/m].to_s
    assert_not_empty start_body, "could not locate startPlanner()"
    assert_includes start_body, 'this.map.once("idle"',
                    "a parked planner state must retry on idle — load can already be running when the gate trips"
  end

  # Regression: pumpCalcQueue guards on `this.inFlightCount < MAX_INFLIGHT`.
  # While the counter was only initialised lazily (`(this.inFlightCount || 0)
  # + 1` inside requestSegment), `undefined < 2` was false, the queue never
  # drained and clicking the map produced NO /planner/calculate request at
  # all. The pipeline state must be initialised in the constructor.
  test "the planner initialises its recalculation queue state before any request" do
    source = Rails.root.join("app/javascript/map/route_planner.js").read
    constructor_body = source[/constructor\([^)]*\) \{.*?\n  \}/m].to_s
    assert_not_empty constructor_body, "could not locate the RoutePlanner constructor"

    assert_includes constructor_body, "this.inFlightCount = 0",
                    "inFlightCount must be initialised to 0 in the constructor — " \
                    "otherwise pumpCalcQueue's `inFlightCount < MAX_INFLIGHT` guard is " \
                    "always false and no segment calculation is ever sent"
    assert_includes constructor_body, "this.queuedSegments = new Set()",
                    "queuedSegments must be initialised in the constructor"
    assert_includes constructor_body, "this.calcTimer = null"

    pump_body = source[/pumpCalcQueue\(\) \{.*?\n  \}/m].to_s
    guard = pump_body[/while \((.*?)&&/, 1].to_s
    assert_includes guard, "inFlightCount", "pumpCalcQueue must bound concurrency on inFlightCount"
  end
end
