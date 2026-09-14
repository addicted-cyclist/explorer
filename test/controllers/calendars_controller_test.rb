# frozen_string_literal: true

require "test_helper"

class CalendarsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(valid_user_attributes)
    sign_in @user
    @route = @user.routes.create!(source: "upload", title: "Ridge loop", duration: 1_800)
  end

  test "allocate creates a calendar entry with the picked date and start time" do
    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "2026-10-28", start_time: "09:30" }

    assert_redirected_to route_path(@route)
    entry = @user.calendar_entries.sole
    assert_equal Date.new(2026, 10, 28), entry.scheduled_on
    assert_equal 9, entry.start_time.hour
    assert_equal 30, entry.start_time.min
    assert_equal 10, entry.end_time.hour # 09:30 + the route's 1800s duration
  end

  test "allocate moves the existing entry instead of duplicating it" do
    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "2026-10-28", start_time: "09:30" }
    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "2026-11-02", start_time: "07:00" }
    assert_equal 1, @user.calendar_entries.count
    entry = @user.calendar_entries.sole
    assert_equal Date.new(2026, 11, 2), entry.scheduled_on
    assert_equal 7, entry.start_time.hour
  end

  test "allocate falls back to the default start time and a one hour duration" do
    @route.update_columns(duration: nil)

    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "2026-10-28" }

    entry = @user.calendar_entries.sole
    assert_equal 8, entry.start_time.hour
    assert_equal 9, entry.end_time.hour
  end

  test "allocate with an unparsable date redirects with an alert and stores nothing" do
    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "not-a-date", start_time: "08:00" }

    assert_redirected_to route_path(@route)
    assert_predicate flash[:alert], :present?
    assert_empty @user.calendar_entries.reload
  end

  test "allocate 404s for a route the user does not own" do
    owner = User.create!(valid_user_attributes(email: "owner@example.com"))
    other = owner.routes.create!(source: "upload", title: "Not mine")

    post allocate_calendar_path, params: { route_id: other.id, scheduled_on: "2026-10-28", start_time: "08:00" }

    assert_response :not_found
  end

  test "remove_entry deletes the route's calendar entry" do
    @user.calendar_entries.create!(route: @route, scheduled_on: Date.new(2026, 10, 28),
                                   start_time: "08:00", end_time: "08:30")

    delete remove_entry_calendar_path, params: { route_id: @route.id }

    assert_redirected_to route_path(@route)
    assert_equal "Removed \"Ridge loop\" from your calendar.", flash[:notice]
    assert_empty @user.calendar_entries.reload
  end
end
