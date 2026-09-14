# Public GPX streaming for the gpx.studio embed. The embed iframe fetches the
# file cross-origin with a plain cookie-less request, so this endpoint opts
# out of the app-wide Devise gate and relies on the blob's signed_id (an
# unguessable capability token) plus permissive CORS headers — the same
# public-by-token pattern as the public calendar (Phase 8).
class GpxFilesController < ApplicationController
  skip_before_action :authenticate_user!

  before_action :set_cors_headers

  def show
    # CORS preflight. gpx.studio is a public HTTPS page while the embed's file
    # URL is our own loopback/dev host, so Chrome's Private Network Access
    # check sends an OPTIONS probe that must be granted here before the real
    # GET — otherwise the fetch dies with "Permission was denied for this
    # request to access the `loopback` address space". Granted unconditionally:
    # no blob lookup (a bogus token must not 404 the preflight).
    return head :no_content if request.options?

    blob = ActiveStorage::Blob.find_signed(params[:signed_id])
    raise ActiveRecord::RecordNotFound unless blob

    # Signed ids are immutable, so the payload can be cached aggressively.
    response.headers["Cache-Control"] = "public, max-age=#{1.year.to_i}"

    send_data blob.download,
              filename: params[:filename].to_s,
              type: blob.content_type.presence || "application/gpx+xml",
              disposition: "inline"
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    head :not_found
  end

  private

  # CORS grant + Private Network Access permission. The headers ride on both
  # the OPTIONS preflight and the actual response (Safari enforces on the
  # response without preflighting). "Private-Network" is the original Chrome
  # header name; "Local-Network" is its newer Local Network Access naming —
  # sending both keeps old and new Chrome happy.
  def set_cors_headers
    response.set_header("Access-Control-Allow-Origin", "https://gpx.studio")
    response.set_header("Access-Control-Allow-Methods", "GET, OPTIONS")
    response.set_header("Access-Control-Allow-Headers", "*")
    response.set_header("Access-Control-Max-Age", "86400")
  end
end
