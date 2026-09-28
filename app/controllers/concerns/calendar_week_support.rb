# Shared week-view plumbing for the calendar controllers: the ?week=YYYY-MM-DD
# resolver and the weekly telemetry totals. Kept in one place so
# CalendarsController (my/friend views) and PublicCalendarController (public
# share) stay in sync.
module CalendarWeekSupport
  extend ActiveSupport::Concern

  private

  # ?week=YYYY-MM-DD pins the visible week; anything unparsable falls back to
  # the current Monday-start week.
  def resolve_week_start
    Date.parse(params[:week].to_s).beginning_of_week
  rescue ArgumentError, TypeError
    Date.current.beginning_of_week
  end

  # Weekly telemetry bar totals (design: "Weekly Planned" km, elevation, count).
  def build_telemetry(entries)
    {
      distance: entries.sum { |entry| entry.route.distance.to_f },
      elevation: entries.sum { |entry| entry.route.elevation_gain.to_f },
      workouts: entries.size
    }
  end
end
