# frozen_string_literal: true

require "test_helper"

class PublicCalendarControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(valid_user_attributes(email: "sharer@example.com"))
    @owner.update!(calendar_public: true)
    @route = @owner.routes.create!(source: "upload", title: "Ridge loop", duration: 1_800)
    @week_start = Date.current.beginning_of_week
    @entry = @owner.calendar_entries.create!(route: @route, scheduled_on: @week_start + 2,
                                             start_time: "08:00", end_time: "08:30")
    # A library route NOT scheduled this week: must never surface on the share.
    @private_pool_route = @owner.routes.create!(source: "upload", title: "Secret climb", duration: 3_600)
  end

  # ---- show ----------------------------------------------------------------

  test "guest sees the shared week read-only" do
    get public_calendar_path(@owner.public_token)

    assert_response :success
    assert_select "h1", text: "#{@owner.name}'s Calendar"
    assert_match "Ridge loop", response.body
    # Share-state badge instead of the friends breadcrumb
    assert_match "Shared calendar · read only", response.body
    # Read-only grid: no drop targets, no dnd forms, no upload modal
    assert_select "div.wc-day__empty", text: /Rest Day/
    assert_select "form.wc-dnd-form", count: 0
    assert_select "#upload", count: 0
    # Week nav stays on the public share URL
    assert_select %(a[href="#{public_calendar_path(@owner.public_token, week: (@week_start + 7).iso8601)}"])
  end

  test "show exposes only the visible week's scheduled routes" do
    get public_calendar_path(@owner.public_token)

    assert_match "Ridge loop", response.body
    assert_no_match "Secret climb", response.body
  end

  test "show renders GPX download links through the signed-id endpoint" do
    @route.gpx_file.attach(gpx_fixture_upload("ridge_loop.gpx"))

    get public_calendar_path(@owner.public_token)

    assert_response :success
    assert_select %(a.wc-gpx-btn[href="#{gpx_file_path(@route.gpx_file.blob.signed_id, "ridge_loop.gpx")}"])
  end

  test "signed-in visitor sees Join docks, not owner controls" do
    visitor = User.create!(valid_user_attributes(email: "visitor@example.com"))
    sign_in visitor

    get public_calendar_path(@owner.public_token)

    assert_response :success
    # One dock per surface: desktop day column + mobile day panel.
    assert_select "form[action*='#{public_calendar_join_path(@owner.public_token)}']", count: 2
    # Owner-only chrome is gone for visitors
    assert_select ".wc-share-btn", count: 0
    assert_select ".wc-entry__remove", count: 0
  end

  test "show 404s an unknown token" do
    get public_calendar_path("nope")

    assert_response :not_found
  end

  test "show 404s after the calendar was made private again" do
    stale_share_url = public_calendar_path(@owner.public_token)
    @owner.update!(calendar_public: false)

    get stale_share_url

    assert_response :not_found
  end

  # ---- join ----------------------------------------------------------------

  test "guest joining is bounced to sign in with the share URL stored" do
    post public_calendar_join_path(@owner.public_token, entry_id: @entry.id)

    assert_redirected_to new_user_session_path
    assert_match(/Sign in to add "Ridge loop"/, flash[:alert])
    assert_equal public_calendar_join_path(@owner.public_token, entry_id: @entry.id),
                 session[:user_return_to]
    assert_empty CalendarEntry.where(origin_entry_id: @entry.id)
  end

  test "signed-in visitor joins from the public page and stays there" do
    visitor = User.create!(valid_user_attributes(email: "visitor@example.com"))
    sign_in visitor

    post public_calendar_join_path(@owner.public_token, entry_id: @entry.id),
         headers: { "ACCEPT" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match "wc-join--joined", response.body
    assert_select "form[action='#{public_calendar_path(@owner.public_token)}']", count: 0 # no bounce anywhere

    copy = visitor.calendar_entries.sole
    assert_equal @entry.id, copy.origin_entry_id
    assert_equal "Ridge loop", copy.route.title
    assert_equal @entry.scheduled_on, copy.scheduled_on
  end

  test "join without turbo redirects back to the public page" do
    visitor = User.create!(valid_user_attributes(email: "visitor2@example.com"))
    sign_in visitor

    post public_calendar_join_path(@owner.public_token, entry_id: @entry.id, week: @week_start.iso8601)

    assert_redirected_to public_calendar_path(@owner.public_token, week: @week_start.iso8601)
    assert_match(/You joined "Ridge loop"/, flash[:notice])
    assert_equal 1, visitor.calendar_entries.count
  end

  test "joining the same public ride twice does not duplicate the copy" do
    visitor = User.create!(valid_user_attributes(email: "dupvisitor@example.com"))
    sign_in visitor

    post public_calendar_join_path(@owner.public_token, entry_id: @entry.id)
    post public_calendar_join_path(@owner.public_token, entry_id: @entry.id)

    assert_equal 1, visitor.calendar_entries.count
    assert_equal 1, visitor.routes.count
  end

  test "join 404s for an entry outside the shared calendar" do
    other = User.create!(valid_user_attributes(email: "otherowner@example.com"))
    other.update!(calendar_public: true)
    other_entry = other.calendar_entries.create!(route: other.routes.create!(source: "upload", title: "Other"),
                                                 scheduled_on: @week_start + 1,
                                                 start_time: "08:00", end_time: "08:30")

    post public_calendar_join_path(@owner.public_token, entry_id: other_entry.id)

    assert_response :not_found
  end
end
