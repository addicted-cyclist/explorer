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
end
