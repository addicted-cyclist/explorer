class RoutesController < ApplicationController
  before_action :set_route, only: %i[show edit update destroy toggle_completed download]

  def index
    @routes = current_user.routes.order(created_at: :desc)
    @stats = library_stats(@routes)
    @new_route = Route.new
  end

  # Interim placeholder until the Phase 6 map detail page lands
  def show
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

  def update
    if @route.update(route_params)
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to routes_path, notice: "Route updated." }
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

  def route_params
    params.require(:route).permit(:title, :description, :tier, :sport_type)
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
