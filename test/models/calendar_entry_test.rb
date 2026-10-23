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

  test "allows an end time before the start time as a midnight-crossing ride" do
    # end_time is a bare time-of-day; the controller derives it as
    # start + moving duration, so 23:30 + 1h wraps to 00:30 on the next day.
    @entry.start_time = "23:30"
    @entry.end_time = "00:30"
    assert_predicate @entry, :valid?
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

  # ---- BUGS item 4: a ride already on my calendar can never be copied ------

  test "join_ride! refuses the origin owner joining their own ride" do
    origin = @user.calendar_entries.create!(route: @route, scheduled_on: Date.new(2026, 10, 28),
                                            start_time: "09:00", end_time: "10:30")

    assert_no_difference -> { @user.routes.count } do
      assert_no_difference -> { @user.calendar_entries.count } do
        error = assert_raises(ActiveRecord::RecordInvalid) do
          CalendarEntry.join_ride!(origin, owner: @user)
        end

        assert_match(/already on your calendar/, error.message)
      end
    end
  end

  test "join_ride! refuses a copy of a copy — second user joining third user's copy of a ride they already have" do
    first = User.create!(valid_user_attributes(email: "chainfirst@example.com"))
    second = User.create!(valid_user_attributes(email: "chainsecond@example.com"))
    third = User.create!(valid_user_attributes(email: "chainthird@example.com"))
    origin_route = first.routes.create!(source: "upload", title: "Chain ride", duration: 3_600)
    origin = first.calendar_entries.create!(route: origin_route, scheduled_on: Date.new(2026, 10, 28),
                                            start_time: "09:00", end_time: "10:00")
    second_copy = CalendarEntry.join_ride!(origin, owner: second)
    third_copy = CalendarEntry.join_ride!(second_copy, owner: third)

    assert_no_difference -> { second.routes.count } do
      assert_no_difference -> { second.calendar_entries.count } do
        error = assert_raises(ActiveRecord::RecordInvalid) do
          CalendarEntry.join_ride!(third_copy, owner: second)
        end

        assert_match(/already on your calendar/, error.message)
      end
    end
  end

  test "join_ride! refuses the origin itself when a copy of the same ride is already mine" do
    first = User.create!(valid_user_attributes(email: "branchfirst@example.com"))
    second = User.create!(valid_user_attributes(email: "branchsecond@example.com"))
    third = User.create!(valid_user_attributes(email: "branchthird@example.com"))
    origin_route = first.routes.create!(source: "upload", title: "Branch ride", duration: 3_600)
    origin = first.calendar_entries.create!(route: origin_route, scheduled_on: Date.new(2026, 10, 28),
                                            start_time: "09:00", end_time: "10:00")
    second_copy = CalendarEntry.join_ride!(origin, owner: second)
    CalendarEntry.join_ride!(second_copy, owner: third) # third's copy, via second

    error = assert_raises(ActiveRecord::RecordInvalid) do
      CalendarEntry.join_ride!(origin, owner: third) # same ride, straight from the origin owner
    end

    assert_match(/already on your calendar/, error.message)
  end

  test "join_ride! refuses sibling copies of the same ride" do
    first = User.create!(valid_user_attributes(email: "sibfirst@example.com"))
    second = User.create!(valid_user_attributes(email: "sibsecond@example.com"))
    third = User.create!(valid_user_attributes(email: "sibthird@example.com"))
    fourth = User.create!(valid_user_attributes(email: "sibfourth@example.com"))
    origin_route = first.routes.create!(source: "upload", title: "Sibling ride", duration: 3_600)
    origin = first.calendar_entries.create!(route: origin_route, scheduled_on: Date.new(2026, 10, 28),
                                            start_time: "09:00", end_time: "10:00")
    second_copy = CalendarEntry.join_ride!(origin, owner: second)
    third_copy = CalendarEntry.join_ride!(second_copy, owner: third)
    fourth_copy = CalendarEntry.join_ride!(origin, owner: fourth) # sibling branch

    error = assert_raises(ActiveRecord::RecordInvalid) do
      CalendarEntry.join_ride!(fourth_copy, owner: third)
    end

    assert_match(/already on your calendar/, error.message)
  end

  test "join_ride! still books a new scheduling of a ride I already joined once" do
    owner = User.create!(valid_user_attributes(email: "rebook@example.com"))
    origin_route = owner.routes.create!(source: "upload", title: "Weekly climb", duration: 3_600)
    week_one = owner.calendar_entries.create!(route: origin_route, scheduled_on: Date.new(2026, 10, 28),
                                              start_time: "09:00", end_time: "10:00")
    first_copy = CalendarEntry.join_ride!(week_one, owner: @user)

    week_two = owner.calendar_entries.create!(route: origin_route, scheduled_on: Date.new(2026, 11, 4),
                                              start_time: "09:00", end_time: "10:00")
    second_copy = CalendarEntry.join_ride!(week_two, owner: @user)

    assert_not_equal first_copy.id, second_copy.id
    assert_equal week_two.id, second_copy.origin_entry_id
  end

  # The ancestry guard must stay query-bounded: one query per chain LEVEL,
  # never one per joined copy — a user with many joins must not pay a
  # growing N+1 on every join POST.
  test "join_ride! ancestry guard stays query-bounded for a user with many joined copies" do
    joiner = User.create!(valid_user_attributes(email: "manyjoins@example.com"))
    6.times do |i|
      origin_owner = User.create!(valid_user_attributes(email: "manyorigin#{i}@example.com"))
      origin = origin_owner.calendar_entries.create!(
        route: origin_owner.routes.create!(source: "upload", title: "Ride #{i}", duration: 3_600),
        scheduled_on: Date.new(2026, 10, 28), start_time: "08:00", end_time: "09:00")
      CalendarEntry.join_ride!(origin, owner: joiner)
    end
    fresh_owner = User.create!(valid_user_attributes(email: "manyfresh@example.com"))
    fresh = fresh_owner.calendar_entries.create!(
      route: fresh_owner.routes.create!(source: "upload", title: "Fresh ride", duration: 3_600),
      scheduled_on: Date.new(2026, 10, 29), start_time: "08:00", end_time: "09:00")

    selects = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      selects += 1 if payload[:sql].to_s.match?(/\A\s*SELECT.*FROM "?calendar_entries"?/i)
    end

    begin
      joined = CalendarEntry.join_ride!(fresh, owner: joiner)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    # The join itself succeeded — the bound is not bought by rejecting.
    assert_equal fresh.id, joined.origin_entry_id
    # Idempotency lookup + copies pluck + one level walk = 3; the old
    # per-copy walk needed 8 for this setup.
    assert selects <= 4, "expected ≤4 calendar_entries SELECTs, got #{selects}"
  end
end
