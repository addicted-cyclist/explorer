class CalendarEntry < ApplicationRecord
  belongs_to :user
  belongs_to :route

  # Set when this entry was created by joining a friend's scheduled ride —
  # the link that keeps the dock's Join → Joined state stable across renders.
  belongs_to :origin_entry, class_name: "CalendarEntry", optional: true

  # Scheduled on a concrete calendar date; start/end are times of day on
  # that date (the detail page's month grid + start-time picker).
  validates :scheduled_on, presence: true
  validates :start_time, presence: true
  validates :end_time, presence: true
  validate :end_time_after_start_time

  scope :between, ->(range) { where(scheduled_on: range) }

  def day_name
    scheduled_on ? scheduled_on.strftime("%A") : "Unknown"
  end

  # Sort key for calendar rendering: date first, then the start time; entries
  # without a start time sink to the bottom of their day.
  def calendar_sort_key
    [ scheduled_on, start_time ? start_time.seconds_since_midnight : Float::INFINITY ]
  end

  # The entry a route's add-to-calendar picker manages: the next upcoming
  # one, else the most recent — so the popover keeps an entry to reschedule
  # or remove even when every ride is in the past. Nil when the route was
  # never scheduled.
  def self.tracked_by_route(route, owner)
    tracked_entry_from(owner.calendar_entries.where(route: route).order(:scheduled_on, :start_time))
  end

  # The .tracked_by_route policy applied to a preloaded, ordered list — the
  # library grid resolves every card's picker state from one query
  # (RoutesController#index) instead of one per route.
  def self.tracked_entry_from(entries)
    entries = entries.to_a
    entries.select { |entry| entry.scheduled_on >= Date.current }
           .min_by(&:calendar_sort_key) ||
      entries.max_by(&:calendar_sort_key)
  end

  # Join a scheduled ride (friend view / public share): deep-copies the
  # origin's route into +owner+'s library (own GPX blob, see
  # Route#deep_copy_for) and books +owner+'s own entry on the same date and
  # time, linked back via origin_entry so the Join docks keep their "Joined"
  # state across renders. Idempotent: a repeated join of the same ride
  # (double POST, stale UI) never deep-copies twice — the existing copy is
  # returned as-is. Raises ActiveRecord::RecordInvalid on a bad booking.
  def self.join_ride!(origin_entry, owner:)
    existing = owner.calendar_entries.find_by(origin_entry_id: origin_entry.id)
    return existing if existing

    route = origin_entry.route.deep_copy_for(owner)
    route.save!
    owner.calendar_entries.create!(
      route: route,
      origin_entry: origin_entry,
      scheduled_on: origin_entry.scheduled_on,
      start_time: origin_entry.start_time,
      # A joined ride is a fresh plan — never born completed, even when the
      # origin ride (or its route) is already done.
      completed: false,
      # The joined entry keeps the origin's scheduled slot; if the origin's
      # end time is missing (legacy rows), rebuild it from the copy's moving
      # duration.
      end_time: origin_entry.end_time || origin_entry.start_time + route.moving_duration
    )
  end

  private

  # end_time is a bare time-of-day (no date column) and the app only derives
  # it as start + the route's moving duration — so an end earlier than the
  # start is a midnight-crossing ride (end on the next day), never garbage.
  # Only an end equal to the start (zero duration) is invalid.
  def end_time_after_start_time
    return if start_time.blank? || end_time.blank?

    errors.add(:end_time, "must be after start time") if end_time == start_time
  end
end
