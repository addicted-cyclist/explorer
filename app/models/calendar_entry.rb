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
      # The joined entry keeps the origin's scheduled slot; if the origin's
      # end time is missing (legacy rows), rebuild it from the copy's moving
      # duration.
      end_time: origin_entry.end_time || origin_entry.start_time + route.moving_duration
    )
  end

  private

  def end_time_after_start_time
    return if start_time.blank? || end_time.blank?

    if end_time <= start_time
      errors.add(:end_time, "must be after start time")
    end
  end
end
