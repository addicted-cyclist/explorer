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
        route: { gpx_files: [gpx_fixture_upload("exploration.gpx")] },
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
      post routes_path, params: { route: { gpx_files: [""] }, commit: "Parse & Import" }
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
        route: { gpx_files: [gpx_fixture_upload("#{"a" * 201}.gpx")] },
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
        route: { gpx_files: [gpx_fixture_upload("broken.gpx", content: "<foo>not a gpx trace</foo>")] },
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
      route: { gpx_files: [gpx_fixture_upload("exploration.gpx")] },
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
end
