# Route Planner HTTP surface (technote.ROUTE-DRAW.md §10.2/§10.4): the ONLY
# door between the planner frontend and the routing engine. The browser never
# talks to BRouter — every segment calculation, every save and every POI
# image upload flows through here, behind the ApplicationController's default
# sign-in + email-verification gates.
#
#   * #calculate — one segment request (RW → SPs → RW coordinate sequence +
#     profile) → GeoJSON geometry + engine metadata. §10.6: failures answer
#     with a user-safe message and NEVER destroy client-side state; the
#     client keeps its last valid geometry and marks the segment failed.
#   * #save — persist the whole editor state via Planner::RouteSaver
#     (validation, stats, GPX generation, RW/SP/POI collections in one
#     transaction). 422 carries the validation errors; 502 the engine being
#     unreachable.
#   * #upload_poi_image — direct upload endpoint for POI imagery: returns a
#     signed_id the save payload references. ActiveStorage handles the bytes;
#     ownership of the blob is irrelevant until a POI references it on save,
#     so no extra authorization surface exists here beyond sign-in.
#   * #state — the editor boot state of ONE owned route (the /map?edit=ID
#     payload as JSON, §2.2): lets the popup's Edit affordance boot the
#     planner in place instead of reloading the whole page. Ownership is the
#     entire authorization model — a foreign route (public included) answers
#     404, indistinguishable from a missing one.
class PlannerController < ApplicationController
  # Client-side errors (bad JSON shapes) are 400; engine trouble 502; a
  # rejected editor state 422 with the human-readable list.
  rescue_from ArgumentError, with: :render_bad_request
  rescue_from Routing::BrouterClient::Error, with: :render_engine_error
  rescue_from Planner::RouteSaver::ValidationError, with: :render_validation_error

  def calculate
    profile = params.require(:profile).to_s
    points = raw_points(params[:points])

    segment = Routing::SegmentCalculator.call(points: points, profile: profile)
    render json: { segment: segment }
  end

  def save
    state = params[:state]
    raise ArgumentError, "missing editor state" unless state.is_a?(ActionController::Parameters)

    route = state[:route_id].present? ? find_owned_route(state[:route_id]) : nil
    saved = Planner::RouteSaver.call(user: current_user, route: route, state: state.to_unsafe_h)

    render json: {
      id: saved.id,
      route_url: route_path(saved.id),
      map_url: map_path(edit: saved.id)
    }
  end

  def upload_poi_image
    image = params.require(:image)
    unless image.is_a?(ActionDispatch::Http::UploadedFile) && image.content_type.to_s.start_with?("image/")
      raise ArgumentError, "image must be an uploaded image file"
    end
    raise ArgumentError, "image must be 5 MB or smaller" if image.size > 5.megabytes

    blob = ActiveStorage::Blob.create_and_upload!(
      io: image,
      filename: image.original_filename.presence || "poi-image",
      content_type: image.content_type
    )
    render json: {
      signed_id: blob.signed_id,
      url: Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)
    }
  end

  # GET /planner/state/:route_id — editor boot state for one owned route: the
  # exact payload the /map?edit=ID deep link ships server-rendered (§2.2), as
  # JSON. The popup's Edit affordance fetches it and boots the planner in
  # place (no page reload); the deep link stays for no-JS and shared URLs.
  def state
    route = current_user.routes.find_by(id: params[:route_id])
    unless route
      return render json: { error: "route not found" }, status: :not_found
    end

    render json: { state: route.planner_state }
  end

  private

  # [lat, lon] pairs, whitelisted into plain floats before anything engine
  # related runs — request data never reaches the adapter unvalidated.
  def raw_points(raw)
    raise ArgumentError, "points must be an array of [lat, lon] pairs" unless raw.is_a?(Array)

    raw.map do |pair|
      raise ArgumentError, "points must be an array of [lat, lon] pairs" unless
        pair.is_a?(Array) && pair.size == 2 && pair.all? { |v| v.is_a?(Numeric) }

      [ Float(pair[0]), Float(pair[1]) ]
    end
  end

  def find_owned_route(id)
    current_user.routes.find(id)
  rescue ActiveRecord::RecordNotFound
    raise ArgumentError, "route not found"
  end

  def render_bad_request(error)
    render json: { error: error.message }, status: :bad_request
  end

  def render_engine_error(error)
    render json: { error: error.message }, status: :bad_gateway
  end

  def render_validation_error(error)
    render json: { error: error.message, errors: error.errors }, status: :unprocessable_entity
  end
end
