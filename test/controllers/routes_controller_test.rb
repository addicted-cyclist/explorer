# frozen_string_literal: true

require "test_helper"

class RoutesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(valid_user_attributes)
    sign_in @user
  end

  test "create imports a gpx file without metadata and titles it from the filename" do
    assert_difference -> { Route.count }, +1 do
      post routes_path, params: {
        route: { gpx_files: [ gpx_fixture_upload("exploration.gpx") ] },
        commit: "Parse & Import"
      }
    end

    assert_redirected_to routes_path
    assert_equal "Imported route: exploration.", flash[:notice]

    route = Route.sole
    assert_equal "exploration", route.title
    assert_equal "upload", route.source
    assert route.gpx_file.attached?
    assert_operator route.distance, :>, 0
    assert_equal 1_800, route.duration
    assert_predicate route.track_svg, :present?
  end

  test "create sends an empty upload back with a flash alert" do
    assert_no_difference -> { Route.count } do
      post routes_path, params: { route: { gpx_files: [ "" ] }, commit: "Parse & Import" }
    end

    assert_redirected_to routes_path
    assert_equal "Choose at least one GPX file to upload.", flash[:alert]
  end

  # Regression from the production log: when the first save! fails (here the
  # filename-derived title exceeds the 200 character limit), the attachment
  # only exists in memory. The cleanup used to call purge_later on that
  # unpersisted blob and 500'd with ActiveJob::SerializationError instead of
  # redirecting with a friendly alert.
  test "create fails gracefully when the filename-derived title is too long" do
    assert_no_difference -> { Route.count } do
      post routes_path, params: {
        route: { gpx_files: [ gpx_fixture_upload("#{"a" * 201}.gpx") ] },
        commit: "Parse & Import"
      }
    end

    assert_redirected_to routes_path
    assert_match(/No routes were imported/, flash[:alert])
    assert_equal 0, ActiveStorage::Blob.count
    assert_equal 0, ActiveStorage::Attachment.count
    assert_no_enqueued_jobs
  end

  test "create destroys a persisted route and purges its blob when parsing fails" do
    assert_no_difference -> { Route.count } do
      post routes_path, params: {
        route: { gpx_files: [ gpx_fixture_upload("broken.gpx", content: "<foo>not a gpx trace</foo>") ] },
        commit: "Parse & Import"
      }
    end

    assert_redirected_to routes_path
    assert_equal "No routes were imported. Failed: broken.gpx.", flash[:alert]

    # route.destroy has already removed the attachment; the blob row goes
    # away once the enqueued ActiveStorage::PurgeJob runs.
    perform_enqueued_jobs
    assert_equal 0, ActiveStorage::Blob.count
    assert_equal 0, ActiveStorage::Attachment.count
  end

  test "create reports every file in a mixed batch" do
    assert_difference -> { Route.count }, +1 do
      post routes_path, params: {
        route: {
          gpx_files: [
            gpx_fixture_upload("exploration.gpx"),
            gpx_fixture_upload("broken.gpx", content: "<foo>not a gpx trace</foo>")
          ]
        },
        commit: "Parse & Import"
      }
    end

    assert_redirected_to routes_path
    assert_equal "Imported route: exploration. Failed: broken.gpx.", flash[:notice]
  end

  # Regression: the library page used to 500 with NoMethodError
  # (undefined method `google_drive?') once any route card or the stats bar
  # rendered, because Route never defined the source predicates.
  test "index renders routes from both sources with library stats" do
    @user.routes.create!(source: "upload", title: "Uploaded ride")
    @user.routes.create!(source: "google_drive", title: "Drive ride", google_drive_file_id: "abc123")

    get routes_path

    assert_response :success
    assert_match "Uploaded ride", response.body
    assert_match "Drive ride", response.body
    assert_match "Local GPX", response.body
    assert_match "Google Drive", response.body
  end

  test "download streams the attached gpx file as an attachment" do
    post routes_path, params: {
      route: { gpx_files: [ gpx_fixture_upload("exploration.gpx") ] },
      commit: "Parse & Import"
    }
    route = Route.sole

    get download_route_path(route)

    assert_response :success
    assert_match(/attachment; filename="exploration\.gpx"/, response.headers["Content-Disposition"])
    assert_match(/<gpx/i, response.body)
  end

  test "download redirects with an alert when no gpx file is attached" do
    route = @user.routes.create!(source: "upload", title: "Bare route")

    get download_route_path(route)

    assert_redirected_to routes_path
    assert_equal "No GPX file is attached to \"Bare route\".", flash[:alert]
  end

  test "download 404s for another user's route" do
    other_user = User.create!(valid_user_attributes(email: "other@example.com"))
    route = other_user.routes.create!(source: "upload", title: "Not mine")

    # show_exceptions is :rescuable in the test env, so the scoped find
    # renders a 404 instead of raising ActiveRecord::RecordNotFound.
    get download_route_path(route)

    assert_response :not_found
  end

  # ---- Phase 6: route detail page ------------------------------------------

  test "show renders the editable owner view" do
    route = create_route_with_gpx(@user)
    route.update!(duration: 22_500) # parse_gpx! derives duration from the file

    get route_path(route)

    assert_response :success
    assert_match route.title, response.body
    assert_match "My Routes", response.body
    assert_match "Download GPX", response.body
    # Linked Est. Duration / Moving Pace inputs (pace-duration controller)
    assert_match "pace-duration", response.body
    assert_match 'value="6h 15m"', response.body
    # Editable tier select + calendar chip, both absent from the friend view
    assert_match 'name="route[tier]"', response.body
    assert_match "Add to calendar", response.body
    # gpx.studio embed points at the public tokenized endpoint
    assert_match "gpx.studio/embed?options=", response.body
    # The embed survives full-page renders without reloading
    assert_match 'id="route-map-frame"', response.body
    assert_match "data-turbo-permanent", response.body
  end

  test "show renders the read-only friend view with save route" do
    owner = User.create!(valid_user_attributes(email: "owner@example.com"))
    Friendship.connect!(owner, @user)
    route = create_route_with_gpx(owner, attrs: { duration: 22_500, tier: "Alpine" })

    get route_path(route)

    assert_response :success
    assert_match "Save Route", response.body
    assert_match "Download GPX", response.body
    assert_match owner.name, response.body
    assert_match "gpx.studio/embed?options=", response.body
    assert_no_match(/name="route\[tier\]"/, response.body)
    assert_no_match(/pace-duration/, response.body)
    assert_no_match(/calendar-picker/, response.body)
  end

  test "show 404s for a stranger without a friendship" do
    owner = User.create!(valid_user_attributes(email: "owner@example.com"))
    route = owner.routes.create!(source: "upload", title: "Not mine")

    get route_path(route)

    assert_response :not_found
  end

  test "save deep-copies a friend's route with its own gpx blob" do
    owner = User.create!(valid_user_attributes(email: "owner@example.com"))
    Friendship.connect!(owner, @user)
    route = create_route_with_gpx(owner, attrs: { description: "High-alpine", duration: 22_500 })

    assert_difference -> { @user.routes.count }, +1 do
      post save_route_path(route)
    end

    saved = @user.routes.sole
    assert_redirected_to route_path(saved)
    assert_equal "Saved \"#{route.title}\" to My Routes.", flash[:notice]
    assert_equal route.title, saved.title
    assert_equal route.description, saved.description
    assert_equal route.distance, saved.distance
    assert_equal route.duration, saved.duration
    assert_equal route.track_svg, saved.track_svg
    # Copy contract: fresh upload, not completed, no Drive lineage
    assert_equal "upload", saved.source
    assert_not saved.completed?
    assert_nil saved.google_drive_file_id
    # The copy owns its own blob: same bytes, different storage row
    assert saved.gpx_file.attached?
    assert_not_equal route.gpx_file.blob.id, saved.gpx_file.blob.id
    assert_equal route.gpx_file.checksum, saved.gpx_file.checksum
  end

  test "saved copy stays intact when the original route is destroyed" do
    owner = User.create!(valid_user_attributes(email: "owner@example.com"))
    Friendship.connect!(owner, @user)
    route = create_route_with_gpx(owner)

    post save_route_path(route)
    saved = @user.routes.sole

    route.destroy
    perform_enqueued_jobs

    assert saved.reload.gpx_file.attached?
    get download_route_path(saved)
    assert_response :success
    assert_match(/<gpx/i, response.body)
  end

  test "editing the saved copy never touches the original" do
    owner = User.create!(valid_user_attributes(email: "owner@example.com"))
    Friendship.connect!(owner, @user)
    route = create_route_with_gpx(owner, attrs: { duration: 22_500 })

    post save_route_path(route)
    saved = @user.routes.sole

    patch route_path(saved), params: { route: { title: "Renamed copy", duration: 7_200 }, from_detail: "1" }

    assert_redirected_to route_path(saved)
    assert_equal "Renamed copy", saved.reload.title
    assert_equal 7_200, saved.duration
    assert_equal "Mont Blanc ridge", route.reload.title
    assert_equal 1_800, route.duration # parse_gpx! derived it from the file
  end

  test "save 404s for a stranger" do
    owner = User.create!(valid_user_attributes(email: "owner@example.com"))
    route = owner.routes.create!(source: "upload", title: "Not mine")

    post save_route_path(route)

    assert_response :not_found
  end

  test "download as a friend streams the owner's gpx" do
    owner = User.create!(valid_user_attributes(email: "owner@example.com"))
    Friendship.connect!(owner, @user)
    route = create_route_with_gpx(owner)

    get download_route_path(route)

    assert_response :success
    assert_match(/attachment; filename="exploration\.gpx"/, response.headers["Content-Disposition"])
  end

  # Plain (no Accept header) requests resolve to the HTML format, so this
  # covers the no-JS fallback: the redirect re-render only happens when Turbo
  # streams are not available.
  test "update from the detail page redirects back to the route" do
    route = create_route_with_gpx(@user)

    patch route_path(route), params: { route: { title: "Renamed" }, from_detail: "1" }

    assert_redirected_to route_path(route)
    assert_equal "Renamed", route.reload.title
  end

  # Turbo submits the inline editors with the stream Accept header. The
  # response must carry only the fragments the committed field can leave
  # stale — never the gpx.studio iframe, or the map would reload after every
  # edit (RoutesController#update -> update_detail.turbo_stream.erb).
  test "update from the detail page streams fragments without re-rendering the map" do
    route = create_route_with_gpx(@user)

    patch route_path(route), params: { route: { title: "Renamed", duration: 7_200 }, from_detail: "1" },
          headers: { "ACCEPT" => Mime[:turbo_stream].to_s }

    assert_response :ok
    assert_equal Mime[:turbo_stream], response.media_type
    assert_match(/action="update" target="route-detail-crumb"/, response.body)
    assert_match(/action="replace" target="route-detail-stats"/, response.body)
    assert_no_match(/gpx\.studio/, response.body)
    assert_nil flash[:notice]
    assert_equal "Renamed", route.reload.title
    assert_equal 7_200, route.duration
  end

  test "title-only update from the detail page leaves the stats row untouched" do
    route = create_route_with_gpx(@user, attrs: { duration: 1_800 })

    patch route_path(route), params: { route: { title: "Renamed" }, from_detail: "1" },
          headers: { "ACCEPT" => Mime[:turbo_stream].to_s }

    assert_response :ok
    assert_match(/action="update" target="route-detail-crumb"/, response.body)
    assert_no_match(/action="replace" target="route-detail-stats"/, response.body)
  end

  test "invalid update from the detail page streams an empty 422" do
    route = create_route_with_gpx(@user, attrs: { duration: 1_800 })

    patch route_path(route), params: { route: { duration: -1 }, from_detail: "1" },
          headers: { "ACCEPT" => Mime[:turbo_stream].to_s }

    assert_response :unprocessable_entity
    assert_no_match(/<turbo-stream/, response.body)
    assert_equal 1_800, route.reload.duration
  end

  test "update rejects a negative duration" do
    route = create_route_with_gpx(@user, attrs: { duration: 1_800 })

    patch route_path(route), params: { route: { duration: -1 }, from_detail: "1" }

    assert_response :unprocessable_entity
    assert_equal 1_800, route.reload.duration
  end

  private

  # Route with an attached, already parsed GPX file (metadata populated).
  def create_route_with_gpx(user, attrs: {})
    user.routes.create!(attrs.reverse_merge(source: "upload", title: "Mont Blanc ridge")).tap do |route|
      route.gpx_file.attach(
        io: File.open(gpx_fixture_upload("exploration.gpx").path),
        filename: "exploration.gpx",
        content_type: "application/gpx+xml"
      )
      route.parse_gpx!
      route.reload
    end
  end
end
