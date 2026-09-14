# Phase 6 scope: scheduling routes onto calendar dates from the route detail
# page (allocate / remove_entry). The weekly grid (show) and entry time
# editing (update_entry) arrive with Phase 7.
class CalendarsController < ApplicationController
  # The weekly calendar grid is Phase 7; until then the nav link lands back
  # on the library instead of erroring.
  def show
    redirect_to routes_path, notice: "The weekly calendar arrives with the next release."
  end

  # One entry per user+route: re-allocating moves the entry to the new date.
  # End time = start + the route's moving duration (1 hour when unknown).
  def allocate
    route = current_user.routes.find(params[:route_id])
    entry = current_user.calendar_entries.find_or_initialize_by(route_id: route.id)
    entry.scheduled_on = parse_scheduled_date
    entry.start_time = parse_start_time
    entry.end_time = entry.start_time + (route.duration.presence || DEFAULT_DURATION)
    entry.save!
    redirect_to route_path(route),
                notice: "Scheduled \"#{route.title}\" for #{entry.scheduled_on.strftime('%b %-d')}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to route_path(route), alert: "Could not schedule route: #{e.message}"
  end

  def remove_entry
    route = current_user.routes.find(params[:route_id])
    current_user.calendar_entries.where(route_id: route.id).destroy_all
    redirect_to route_path(route), notice: "Removed \"#{route.title}\" from your calendar."
  end

  private

  DEFAULT_DURATION = 1.hour
  DEFAULT_START_TIME = "08:00"

  def parse_scheduled_date
    Date.parse(params[:scheduled_on].to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # Only accept HH:MM / H:MM values from the picker; anything else (or blank)
  # falls back to the design's default start time.
  def parse_start_time
    raw = params[:start_time].to_s
    raw.match?(/\A\d{1,2}:\d{2}\z/) ? raw : DEFAULT_START_TIME
  end
end
