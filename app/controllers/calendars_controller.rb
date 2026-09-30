# The weekly training calendar (Phase 7). `show` renders my week (/calendar)
# or an accepted friend's week (/calendar/:username) from one template that
# branches on @is_friend_view. allocate / update_entry / remove_entry serve
# two callers: the route detail page (plain redirects, Phase 6 behavior) and
# the calendar grid (from_calendar=1 — Turbo Stream fragment swaps of the
# affected day column plus the telemetry bar, with a redirect fallback for
# no-JS browsers). The public share (Phase 9) lives in
# PublicCalendarController; both controllers share CalendarWeekSupport.
class CalendarsController < ApplicationController
  include CalendarWeekSupport

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
    # Friend view: which of this week's rides I already joined — the dock
    # shows the inert "Joined" state for them, stable across reloads.
    @joined_origin_ids =
      if @is_friend_view
        current_user.calendar_entries
                    .where(origin_entry_id: @week_entries.map(&:id))
                    .pluck(:origin_entry_id)
      end
    @telemetry = build_telemetry(@week_entries)
    @sidebar_routes =
      if @is_friend_view
        # Friend view: only the routes scheduled this week, in week order.
        @week_entries.sort_by(&:calendar_sort_key).map(&:route).uniq
      else
        # My view: the whole library is the drag pool.
        current_user.routes.order(created_at: :desc, id: :desc)
      end
    # The shared upload dialog behind the sidebar's "Import new GPX" CTA
    # (same modal the routes library renders).
    @new_route = current_user.routes.new unless @is_friend_view
  rescue ActiveRecord::RecordNotFound
    # prepare_friend_view's guard: a stranger's (or a pending-friend's)
    # calendar stays invisible — bounce to my calendar with an alert.
    redirect_to calendar_path,
    alert: "Can not get access to stranger's calendar!"
  end

  # One entry per user+route. End time = start + the route's moving duration (1 hour when
  # unknown or zero). Drops from the calendar grid submit with from_calendar=1.
  def allocate
    route = current_user.routes.find(params[:route_id])
    entry = current_user.calendar_entries.find_or_initialize_by(route_id: route.id)
    entry.scheduled_on = parse_scheduled_date

    if entry.scheduled_on.nil?
      return redirect_to calendar_fallback_path(route_path(route)),
                         alert: "Pick a valid date to schedule \"#{route.title}\"."
    end

    entry.start_time = parse_start_time
    entry.end_time = entry.start_time + route.moving_duration
    entry.save!

    respond_to do |format|
      format.turbo_stream do
        prepare_week_state
        @entry = entry
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
    entry.end_time = entry.start_time + entry.route.moving_duration
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

  # Join a friend's scheduled ride: the model-level CalendarEntry.join_ride!
  # deep-copies their route into my library (own GPX blob, see
  # Route#deep_copy_for) and books my own entry on the same date and time,
  # linked back via origin_entry so the dock keeps its "Joined" state across
  # renders. The card swaps to the inert "Joined" state in place; without JS
  # we bounce back to the friend's calendar.
  def join
    friend_entry = CalendarEntry.find(params[:entry_id])
    friend = friend_entry.user
    raise ActiveRecord::RecordNotFound unless current_user.friends_with?(friend)

    joined_entry = CalendarEntry.join_ride!(friend_entry, owner: current_user)

    respond_to do |format|
      format.turbo_stream do
        @entry = friend_entry
        @is_friend_view = true # the stream repaints the friend-view card
        # Same week-context contract as prepare_week_state, so any template in
        # the repaint can read @week_start instead of crashing on nil
        @week_start = resolve_week_start
        # Phase 8: the mobile day-panel repaint needs the week's entries, and
        # its entry card derives the "Joined" dock state from this set.
        @week_entries = friend.calendar_entries
                              .includes(:route)
                              .between(@week_start..(@week_start + 6)).to_a
        @joined_origin_ids = [ friend_entry.id ]
        render :join
      end
      format.html do
        redirect_to friend_calendar_path(friend.username, week: params[:week]),
                    notice: "You joined \"#{joined_entry.route.title}\" — it is on your calendar for " \
                            "#{friend_entry.scheduled_on.strftime('%b %-d')}."
      end
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_to calendar_path(week: params[:week]), alert: "Could not join route: #{e.message}"
  end

  private

  # Shared template branch: my calendar vs a friend's. Only accepted friends
  # are viewable — an unknown username, a stranger's calendar, or a
  # pending-friend request all 404 (the show rescue bounces to my calendar).
  def prepare_friend_view
    @is_friend_view = params[:username].present?
    return unless @is_friend_view

    friend = User.find_by(username: params[:username])
    raise ActiveRecord::RecordNotFound unless friend && current_user.friends_with?(friend)

    @friend = friend
  end

  # Recomputes the week context after a mutation so stream templates can
  # repaint the affected day column(s) and the telemetry bar from fresh data.
  # (?week resolution + telemetry totals live in CalendarWeekSupport.)
  def prepare_week_state
    @week_start = resolve_week_start
    @is_friend_view = false
    @week_entries = current_user.calendar_entries
                                .includes(:route)
                                .between(@week_start..(@week_start + 6)).to_a
    @telemetry = build_telemetry(@week_entries)
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
