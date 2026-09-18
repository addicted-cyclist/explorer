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

  private

  def end_time_after_start_time
    return if start_time.blank? || end_time.blank?

    if end_time <= start_time
      errors.add(:end_time, "must be after start time")
    end
  end
end
