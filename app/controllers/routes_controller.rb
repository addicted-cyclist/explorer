class RoutesController < ApplicationController
  # Privilege-sensitive actions stay owner-scoped; show/download/save open up
  # to accepted friends (read-only other-user detail view, Phase 6).
  before_action :set_route, only: %i[edit update destroy toggle_completed]
  before_action :set_viewable_route, only: %i[show download save]

  def index
    @routes = current_user.routes.order(created_at: :desc)
    @stats = library_stats(@routes)
    @new_route = Route.new
  end

  # Phase 6 detail page: the owner gets the editable MY view, an accepted
  # friend gets the read-only OTHER view with Save Route (see show.html.erb).
  def show
    @is_owner = @route.user == current_user
    @calendar_entry = @is_owner ? current_user.calendar_entries.find_by(route: @route) : nil
  end

  def edit
  end

  def create
    files = Array(params.dig(:route, :gpx_files)).compact_blank
    if files.empty?
      redirect_to routes_path, alert: "Choose at least one GPX file to upload." and return
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
      redirect_to routes_path, notice: notice
    else
      redirect_to routes_path, alert: "No routes were imported. Failed: #{failed.join(', ')}."
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

  def toggle_completed
    @route.update!(completed: !@route.completed)
    notice = @route.completed ? "Marked \"#{@route.title}\" as completed." : "Marked \"#{@route.title}\" as not completed."
    if params[:from_calendar].present?
      # The checkbox lives in a calendar day column: repaint just that column
      # and keep the classic redirect as the no-JS fallback.
      @entry = current_user.calendar_entries.find_by(route: @route)
      @week_start = resolve_calendar_week
      @week_entries = current_user.calendar_entries
                                   .includes(:route)
                                   .between(@week_start..(@week_start + 6)).to_a
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to calendar_path(week: params[:week]), notice: notice }
      end
    else
      redirect_to routes_path, notice: notice
    end
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

  # Week context for calendar-originated streams (from_calendar=1): the
  # visible week rides along in the form payload.
  def resolve_calendar_week
    Date.parse(params[:week].to_s).beginning_of_week
  rescue ArgumentError, TypeError
    Date.current.beginning_of_week
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

  def library_stats(routes)
    completed = routes.select(&:completed)
    {
      total_count: routes.size,
      completed_count: completed.size,
      total_distance: routes.sum { |r| r.distance.to_f },
      completed_distance: completed.sum { |r| r.distance.to_f },
      total_elevation: routes.sum { |r| r.elevation_gain.to_f },
      completed_elevation: completed.sum { |r| r.elevation_gain.to_f },
      synced_count: routes.count(&:google_drive?)
    }
  end
end
