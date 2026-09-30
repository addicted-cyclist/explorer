# frozen_string_literal: true

require "test_helper"

class CalendarEntryTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(valid_user_attributes)
    @route = @user.routes.create!(source: "upload", title: "Ridge loop")
    @entry = @user.calendar_entries.build(
      route: @route,
      scheduled_on: Date.new(2026, 10, 28),
      start_time: "08:00",
      end_time: "08:30"
    )
  end

  test "is valid with a scheduled date and times" do
    assert_predicate @entry, :valid?
    assert_equal "Wednesday", @entry.day_name
  end

  test "requires a scheduled date" do
    @entry.scheduled_on = nil
    assert_not @entry.valid?
    assert_includes @entry.errors[:scheduled_on], "can't be blank"
  end

  test "requires end time after start time" do
    @entry.end_time = "08:00"
    assert_not @entry.valid?
    assert_includes @entry.errors[:end_time], "must be after start time"
  end

  test "between matches only entries inside the date range" do
    @entry.save!
    other = @user.calendar_entries.create!(route: @route, scheduled_on: Date.new(2026, 11, 3),
                                           start_time: "07:00", end_time: "07:30")

    week = Date.new(2026, 10, 26)..Date.new(2026, 11, 1)
    assert_includes @user.calendar_entries.between(week), @entry
    assert_not_includes @user.calendar_entries.between(week), other
  end

  # ---- join_ride! (Phase 9 — friend view + public share) --------------------

  test "join_ride! deep-copies the route and books my entry on the origin's slot" do
    owner = User.create!(valid_user_attributes(email: "origin@example.com"))
    origin_route = owner.routes.create!(source: "upload", title: "Shared climb", duration: 5_400)
    origin = owner.calendar_entries.create!(route: origin_route, scheduled_on: Date.new(2026, 10, 28),
                                            start_time: "09:00", end_time: "10:30")

    joined = CalendarEntry.join_ride!(origin, owner: @user)

    assert_equal origin.id, joined.origin_entry_id
    assert_equal Date.new(2026, 10, 28), joined.scheduled_on
    assert_equal "09:00", joined.start_time.strftime("%H:%M")
    assert_equal "10:30", joined.end_time.strftime("%H:%M")
    assert_equal "Shared climb", joined.route.title
    assert_equal @user.id, joined.route.user_id
    assert_not_predicate joined.route, :completed?
  end

  test "join_ride! rebuilds a missing origin end time from the copy's moving duration" do
    owner = User.create!(valid_user_attributes(email: "origin2@example.com"))
    origin_route = owner.routes.create!(source: "upload", title: "Short spin", duration: nil)
    origin = owner.calendar_entries.create!(route: origin_route, scheduled_on: Date.new(2026, 10, 28),
                                            start_time: "09:00", end_time: "10:00")
    origin.update_columns(end_time: nil) # legacy row without an end time

    joined = CalendarEntry.join_ride!(origin, owner: @user)

    # End rebuilt from the copy's moving duration (Route default = 1 hour).
    assert_equal "10:00", joined.end_time.strftime("%H:%M")
  end

  test "join_ride! books a fresh, not-completed entry even when the origin ride is done" do
    owner = User.create!(valid_user_attributes(email: "doneorigin@example.com"))
    origin_route = owner.routes.create!(source: "upload", title: "Done climb", duration: 3_600, completed: true)
    origin = owner.calendar_entries.create!(route: origin_route, scheduled_on: Date.new(2026, 10, 28),
                                            start_time: "09:00", end_time: "10:00", completed: true)

    joined = CalendarEntry.join_ride!(origin, owner: @user)

    assert_not_predicate joined, :completed?
    assert_not_predicate joined.route, :completed?
  end

  test "join_ride! is idempotent — no second copy for a repeated join" do
    owner = User.create!(valid_user_attributes(email: "origin3@example.com"))
    origin_route = owner.routes.create!(source: "upload", title: "Once only", duration: 3_600)
    origin = owner.calendar_entries.create!(route: origin_route, scheduled_on: Date.new(2026, 10, 28),
                                            start_time: "09:00", end_time: "10:00")

    first = CalendarEntry.join_ride!(origin, owner: @user)
    second = CalendarEntry.join_ride!(origin, owner: @user)

    assert_equal first.id, second.id
    assert_equal 1, @user.calendar_entries.where(origin_entry_id: origin.id).count
    assert_equal 1, @user.routes.where(title: "Once only").count
  end
end
