class CalendarEntry < ApplicationRecord
  belongs_to :user
  belongs_to :route

  # Day of week: 0 = Sunday, 1 = Monday, ... 6 = Saturday
  validates :day_of_week, presence: true, inclusion: { in: 0..6 }
  validates :start_time, presence: true
  validates :end_time, presence: true
  validate :end_time_after_start_time

  DAYS_OF_WEEK = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday].freeze

  def day_name
    DAYS_OF_WEEK[day_of_week] || "Unknown"
  end

  private

  def end_time_after_start_time
    return if start_time.blank? || end_time.blank?

    if end_time <= start_time
      errors.add(:end_time, "must be after start time")
    end
  end
end
