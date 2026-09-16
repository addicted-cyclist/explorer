# The weekly training calendar (Phase 7). `show` renders my week (/calendar)
# or an accepted friend's week (/calendar/:username) from one template that
# branches on @is_friend_view. allocate / update_entry / remove_entry serve
# two callers: the route detail page (plain redirects, Phase 6 behavior) and
# the calendar grid (from_calendar=1 — Turbo Stream fragment swaps of the
# affected day column plus the telemetry bar, with a redirect fallback for
# no-JS browsers).
class CalendarsController < ApplicationController
  DEFAULT_DURATION = 1.hour
  DEFAULT_START_TIME = "08:00"

  # GET /calendar (mine) — drag routes from the sidebar onto days.
  # GET /calendar/:username — read-only friend view with per-entry Join.
  def show
    prepare_friend_view
    @week_start = resolve_week_start
    owner = @is_friend_view ? @friend : current_user
    @week_entries = owner.calendar_entries
                         .includes(:route)
                         .between(@week_start..(@week_start + 6)).to_a
    @telemetry = build_telemetry(@week_entries)
    @sidebar_routes =
      if @is_friend_view
        # Friend view: only the routes scheduled this week, in week order.
        @week_entries.sort_by(&:calendar_sort_key).map(&:route).uniq
      else
        # My view: the whole library is the drag pool.
        current_user.routes.order(created_at: :desc, id: :desc)
      end
  end

  # One entry per user+route: re-allocating a scheduled route moves it to the
  # new date. End time = start + the route's moving duration (1 hour when
  # unknown or zero). Drops from the calendar grid submit with from_calendar=1.
  def allocate
    route = current_user.routes.find(params[:route_id])
    entry = current_user.calendar_entries.find_or_initialize_by(route_id: route.id)
    moved_from = entry.new_record? ? nil : entry.scheduled_on
    entry.scheduled_on = parse_scheduled_date

    if entry.scheduled_on.nil?
      return redirect_to calendar_fallback_path(route_path(route)),
                         alert: "Pick a valid date to schedule \"#{route.title}\"."
    end

    entry.start_time = parse_start_time
    entry.end_time = entry.start_time + moving_duration(route)
    entry.save!

    respond_to do |format|
      format.turbo_stream do
        prepare_week_state
        @entry = entry
        @moved_from_date = moved_from
        render :allocate
      end
      format.html do
        redirect_to calendar_fallback_path(route_path(route)),
                    notice: "Scheduled \"#{route.title}\" for #{entry.scheduled_on.strftime('%b %-d')}."
      end
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_to calendar_fallback_path(route_path(route)),
                alert: "Could not schedule route: #{e.message}"
  end

  # Start-time editor on my scheduled cards; end time keeps the moving
  # duration (1 hour when unknown). Scoped to the current user's entries —
  # anything else 404s like the scoped finds.
  def update_entry
    entry = current_user.calendar_entries.find(params[:entry_id])
    entry.start_time = parse_start_time
    entry.end_time = entry.start_time + moving_duration(entry.route)
    entry.save!

    respond_to do |format|
      format.turbo_stream do
        prepare_week_state
        @entry = entry
        render :update_entry
      end
      format.html do
        redirect_to calendar_fallback_path(route_path(entry.route)),
                    notice: "Start time updated for \"#{entry.route.title}\"."
      end
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_to calendar_path(week: params[:week]), alert: "Could not update start time: #{e.message}"
  end

  # Unschedules a route without deleting it from the library (calendar day
  # drop-out / detail page's "Remove from calendar").
  def remove_entry
    route = current_user.routes.find(params[:route_id])
    removed_date = current_user.calendar_entries.find_by(route_id: route.id)&.scheduled_on
    current_user.calendar_entries.where(route_id: route.id).destroy_all

    respond_to do |format|
      format.turbo_stream do
        prepare_week_state
        @removed_date = removed_date
        render :remove_entry
      end
      format.html do
        redirect_to calendar_fallback_path(route_path(route)),
                    notice: "Removed \"#{route.title}\" from your calendar."
      end
    end
  end

  # Join a friend's scheduled ride: deep-copies their route into my library
  # (own GPX blob, see Route#deep_copy_for) and books my own entry on the
  # same date and time. The popover's action area swaps to the "Joined Ride"
  # state in place; without JS we bounce back to the friend's calendar.
  def join
    friend_entry = CalendarEntry.find(params[:entry_id])
    friend = friend_entry.user
    raise ActiveRecord::RecordNotFound unless current_user.friends_with?(friend)

    route = friend_entry.route.deep_copy_for(current_user)
    route.save!
    current_user.calendar_entries.create!(
      route: route,
      scheduled_on: friend_entry.scheduled_on,
      start_time: friend_entry.start_time,
      end_time: joined_end_time(route, friend_entry)
    )

    respond_to do |format|
      format.turbo_stream do
        @entry = friend_entry
        @is_friend_view = true # the stream repaints the friend-view card
        render :join
      end
      format.html do
        redirect_to friend_calendar_path(friend.username, week: params[:week]),
                    notice: "You joined \"#{route.title}\" — it is on your calendar for " \
                            "#{friend_entry.scheduled_on.strftime('%b %-d')}."
      end
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_to calendar_path(week: params[:week]), alert: "Could not join route: #{e.message}"
  end

  private

  # Shared template branch: my calendar vs a friend's. Only accepted friends
  # are viewable; strangers (and the current user's own username) get a 404
  # like the scoped finds.
  def prepare_friend_view
    @is_friend_view = params[:username].present?
    return unless @is_friend_view

    friend = User.find_by(username: params[:username])
    raise ActiveRecord::RecordNotFound unless friend && current_user.friends_with?(friend)

    @friend = friend
  end

  # ?week=YYYY-MM-DD pins the visible week; anything unparsable falls back to
  # the current Monday-start week.
  def resolve_week_start
    Date.parse(params[:week].to_s).beginning_of_week
  rescue ArgumentError, TypeError
    Date.current.beginning_of_week
  end

  # Recomputes the week context after a mutation so stream templates can
  # repaint the affected day column(s) and the telemetry bar from fresh data.
  def prepare_week_state
    @week_start = resolve_week_start
    @is_friend_view = false
    @week_entries = current_user.calendar_entries
                                .includes(:route)
                                .between(@week_start..(@week_start + 6)).to_a
    @telemetry = build_telemetry(@week_entries)
  end

  # Weekly telemetry bar totals (design: "Weekly Planned" km, elevation, count).
  def build_telemetry(entries)
    {
      distance: entries.sum { |entry| entry.route.distance.to_f },
      elevation: entries.sum { |entry| entry.route.elevation_gain.to_f },
      workouts: entries.size
    }
  end

  # The joined entry keeps the friend's scheduled slot; if their end time is
  # missing, rebuild it from my copy's moving duration.
  def joined_end_time(copy, friend_entry)
    friend_entry.end_time ||
      friend_entry.start_time + moving_duration(copy)
  end

  # Moving duration in seconds for end-time math. Zero/nil durations (GPX
  # files without usable timestamps) fall back to the 1-hour default —
  # `0.presence` is 0, so a bare `duration.presence || default` would compute
  # end == start and trip the end-time validation.
  def moving_duration(route)
    route.duration.to_i.positive? ? route.duration : DEFAULT_DURATION
  end

  # The detail page (no from_calendar param) keeps its Phase 6 redirect
  # target; calendar-originated mutations bounce back to the visited week.
  def calendar_fallback_path(default_path)
    params[:from_calendar].present? ? calendar_path(week: params[:week]) : default_path
  end

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
