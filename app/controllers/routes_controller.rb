class RoutesController < ApplicationController
  # Privilege-sensitive actions stay owner-scoped; show/download/save open up
  # to accepted friends (read-only other-user detail view, Phase 6).
  before_action :set_route, only: %i[edit update destroy toggle_completed]
  before_action :set_viewable_route, only: %i[show download save]

  # Phase 0 capacity — the library picker's tracked-entry query used to load
  # the user's entire scheduling history on every index render. Bounded now:
  # rides within the planner horizon count as "upcoming", and a recent-past
  # window covers the "most recent" fallback. Anything older simply renders
  # the default "Add to calendar" chip — those entries stay fully manageable
  # on the calendar itself.
  PICKER_UPCOMING_HORIZON = 1.year
  PICKER_RECENT_PAST_WINDOW = 90.days

  def index
    @routes = current_user.routes.order(created_at: :desc)
    @stats = library_stats(@routes)
    @new_route = Route.new
    # Two bounded queries for the whole grid: each card's calendar button
    # tracks the route's next upcoming entry (else its most recent), so it can
    # commit a reschedule or a Remove without a reload.
    @calendar_entries_by_route = tracked_entries_by_route(@routes)
  end

  # Phase 6 detail page: the owner gets the editable MY view, an accepted
  # friend gets the read-only OTHER view with Save Route (see show.html.erb).
  def show
    @is_owner = @route.user == current_user
    # The add-to-calendar chip tracks this route's next upcoming entry (the
    # route can be scheduled several times); with nothing upcoming it falls
    # back to the most recent one, so the popover keeps managing an entry.
    @calendar_entry =
      if @is_owner
        CalendarEntry.tracked_by_route(@route, current_user)
      end
  end

  def edit
  end

  def create
    files = Array(params.dig(:route, :gpx_files)).compact_blank
    if files.empty?
      redirect_to upload_return_path, alert: "Choose at least one GPX file to upload." and return
    end

    imported, failed = [], []

    files.each do |file|
      route = current_user.routes.build(
        source: "upload",
        title: File.basename(file.original_filename.to_s, ".*").presence || "Untitled"
      )
      route.gpx_file.attach(io: file.tempfile, filename: file.original_filename, content_type: file.content_type)
      route.save!
      route.parse_gpx!
      imported << route
    rescue StandardError => e
      Rails.logger.warn("GPX import failed for #{file.original_filename}: #{e.class} #{e.message}")
      discard_failed_upload(route)
      failed << file.original_filename
    end

    if imported.any?
      notice = "Imported #{'route'.pluralize(imported.size)}: #{imported.map(&:title).join(', ')}."
      notice += " Failed: #{failed.join(', ')}." if failed.any?
      redirect_to upload_return_path, notice: notice
    else
      redirect_to upload_return_path, alert: "No routes were imported. Failed: #{failed.join(', ')}."
    end
  end

  # Deep-copies a friend's (or my own) route into my library — every column
  # is copied as a plain value and the GPX file gets a fresh blob, so the
  # copy and the original never share state (Route#deep_copy_for).
  def save
    saved = @route.deep_copy_for(current_user)
    saved.save!
    redirect_to route_path(saved), notice: "Saved \"#{saved.title}\" to My Routes."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to route_path(@route), alert: "Could not save route: #{e.message}"
  end

  def update
    # The stream response re-renders the stats partial, which branches on
    # @is_owner like the show view does. set_route only ever finds the
    # current user's own routes, so detail-page editors are always the owner.
    @is_owner = true

    if @route.update(route_params)
      if params[:from_detail].present?
        # Inline editors on the detail page commit one field at a time and the
        # page answers with fragment streams (update_detail.turbo_stream.erb):
        # the gpx.studio iframe in _detail_map is never part of the response,
        # so the embedded map does not reload after every edit. The HTML
        # fallback (JS off) keeps the classic redirect re-render.
        respond_to do |format|
          format.turbo_stream { render :update_detail }
          format.html { redirect_to route_path(@route), notice: "Route updated." }
        end
      else
        respond_to do |format|
          # The library modal's stream template replaces the route card and
          # closes the modal in place; its HTML fallback lands in the library.
          format.turbo_stream
          format.html { redirect_to routes_path, notice: "Route updated." }
        end
      end
    else
      if params[:from_detail].present?
        # Validation failures also stay on the page without a full re-render:
        # update_detail's saved_change_to_* guards render an empty stream for
        # the 422, so the edited input keeps the user's text for correction.
        respond_to do |format|
          format.turbo_stream { render :update_detail, status: :unprocessable_entity }
          format.html { render :edit, status: :unprocessable_entity }
        end
      else
        render :edit, status: :unprocessable_entity
      end
    end
  end

  def destroy
    title = @route.title
    @route.destroy
    # Deleting from the calendar sidebar's kebab menu bounces back to the
    # visited week; library deletes keep landing in the library.
    if params[:from_calendar].present?
      redirect_to calendar_path(week: params[:week]), notice: "Route \"#{title}\" deleted."
    else
      redirect_to routes_path, notice: "Route \"#{title}\" deleted."
    end
  end

  # Library-only kebab action: flips the route's stored Done badge. The
  # calendar's per-entry checkboxes answer to CalendarsController
  # #toggle_completed instead (one-way entry → route sync).
  def toggle_completed
    @route.update!(completed: !@route.completed)
    notice = @route.completed ? "Marked \"#{@route.title}\" as completed." : "Marked \"#{@route.title}\" as not completed."
    redirect_to routes_path, notice: notice
  end

  def download
    unless @route.gpx_file.attached?
      redirect_to routes_path, alert: "No GPX file is attached to \"#{@route.title}\"." and return
    end

    send_data @route.gpx_file.download,
              filename: @route.gpx_file.filename.to_s,
              type: @route.gpx_file.content_type || "application/gpx+xml",
              disposition: "attachment"
  end

  private

  def set_route
    @route = current_user.routes.find(params[:id])
  end

  # Read access: the owner or one of their accepted friends. Everyone else
  # (including signed-in strangers) gets a 404, like the scoped finds.
  def set_viewable_route
    @route = Route.find(params[:id])
    return if @route.user == current_user || @route.user.friends_with?(current_user)

    raise ActiveRecord::RecordNotFound
  end

  # The shared upload modal also opens from the calendar sidebar's "Import
  # new GPX" CTA; when it does (from_calendar=1 + week), land back on the
  # visited week instead of the library (same contract as destroy).
  def upload_return_path
    params[:from_calendar].present? ? calendar_path(week: params[:week]) : routes_path
  end

  def route_params
    params.require(:route).permit(:title, :description, :tier, :sport_type, :duration)
  end

  # Remove a route that failed mid-import so no broken rows or orphaned
  # blobs are left behind.
  def discard_failed_upload(route)
    if route.persisted?
      route.destroy
    elsif route.gpx_file.attached? && route.gpx_file.blob.persisted?
      route.gpx_file.blob.purge_later
    end
  end

  # Phase 0 capacity: resolve every card's picker state from two bounded
  # queries instead of the full entry history — the earliest ride inside
  # PICKER_UPCOMING_HORIZON wins; routes without one fall back to their most
  # recent ride within PICKER_RECENT_PAST_WINDOW. Same tracked-entry policy
  # as CalendarEntry.tracked_entry_from (upcoming-else-most-recent), minus
  # the unbounded load of every ride ever scheduled.
  def tracked_entries_by_route(routes)
    upcoming = current_user.calendar_entries
                           .where(route: routes,
                                  scheduled_on: Date.current..PICKER_UPCOMING_HORIZON.from_now.to_date)
                           .order(:scheduled_on, :start_time)
                           .group_by(&:route_id)
                           .transform_values { |entries| entries.min_by(&:calendar_sort_key) }

    recent = current_user.calendar_entries
                         .where(route: routes,
                                scheduled_on: PICKER_RECENT_PAST_WINDOW.ago.to_date...Date.current)
                         .order(scheduled_on: :desc, start_time: :desc)
                         .group_by(&:route_id)
                         .transform_values(&:first)

    recent.merge(upcoming)
  end

  # Phase 0 capacity: the stats bar aggregates in SQL (one query) instead of
  # iterating the whole loaded library in Ruby — it stays correct when the
  # grid later becomes paginated and scales past in-memory sums. CASE WHEN
  # keeps the conditional sums portable across SQLite / Postgres / MySQL.
  def library_stats(routes)
    total_count, completed_count, total_distance, completed_distance,
      total_elevation, completed_elevation, synced_count =
      # unscope(:order): an aggregate must not inherit the grid's ORDER BY —
      # Postgres rejects ORDER BY columns that aren't grouped/aggregated
      # (PG::GroupingError); SQLite would silently tolerate it.
      routes.unscope(:order).pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("SUM(CASE WHEN completed THEN 1 ELSE 0 END)"),
        Arel.sql("COALESCE(SUM(distance), 0)"),
        Arel.sql("COALESCE(SUM(CASE WHEN completed THEN distance ELSE 0 END), 0)"),
        Arel.sql("COALESCE(SUM(elevation_gain), 0)"),
        Arel.sql("COALESCE(SUM(CASE WHEN completed THEN elevation_gain ELSE 0 END), 0)"),
        Arel.sql("SUM(CASE WHEN source = 'google_drive' THEN 1 ELSE 0 END)")
      )

    {
      total_count: total_count.to_i,
      completed_count: completed_count.to_i,
      total_distance: total_distance.to_f,
      completed_distance: completed_distance.to_f,
      total_elevation: total_elevation.to_f,
      completed_elevation: completed_elevation.to_f,
      synced_count: synced_count.to_i
    }
  end
end
