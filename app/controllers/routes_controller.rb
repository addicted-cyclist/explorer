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

  # Deep-copies a friend's (or my own) route into my library. Every column is
  # copied as a plain value and the GPX file gets a fresh blob, so the copy
  # and the original never share state — editing, re-uploading or deleting
  # one can never affect the other.
  def save
    saved = current_user.routes.build(
      title: @route.title,
      description: @route.description,
      distance: @route.distance,
      elevation_gain: @route.elevation_gain,
      elevation_loss: @route.elevation_loss,
      min_elevation: @route.min_elevation,
      max_elevation: @route.max_elevation,
      duration: @route.duration,
      tier: @route.tier,
      sport_type: @route.sport_type,
      track_svg: @route.track_svg,
      source: "upload",
      completed: false
    )
    copy_gpx_file(@route, saved)
    saved.save!
    redirect_to route_path(saved), notice: "Saved \"#{saved.title}\" to My Routes."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to route_path(@route), alert: "Could not save route: #{e.message}"
  end

  def update
    if @route.update(route_params)
      respond_to do |format|
        if params[:from_detail].present?
          # Inline editors on the detail page bounce back to the route; the
          # library modal's turbo_stream template targets cards that don't
          # exist on the detail page.
          format.turbo_stream { redirect_to route_path(@route), status: :see_other, notice: "Route updated." }
          format.html { redirect_to route_path(@route), notice: "Route updated." }
        else
          format.turbo_stream
          format.html { redirect_to routes_path, notice: "Route updated." }
        end
      end
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    title = @route.title
    @route.destroy
    redirect_to routes_path, notice: "Route \"#{title}\" deleted."
  end

  def toggle_completed
    @route.update!(completed: !@route.completed)
    redirect_to routes_path, notice: @route.completed ? "Marked \"#{@route.title}\" as completed." : "Marked \"#{@route.title}\" as not completed."
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

  # Attach a byte-for-byte copy of +source+'s GPX under +target+'s own blob —
  # sharing the blob would let a purge on either side destroy both.
  def copy_gpx_file(source, target)
    return unless source.gpx_file.attached?

    # Read the bytes up front: `source.gpx_file.open` would scope a Tempfile to
    # this block, but the target's upload is deferred until save! — by then the
    # Tempfile is already closed. GPX files are small, so buffering is safe.
    target.gpx_file.attach(
      io: StringIO.new(source.gpx_file.download),
      filename: source.gpx_file.filename,
      content_type: source.gpx_file.content_type
    )
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
