# frozen_string_literal: true

# Cacheable serving of the route static map thumb (the Mapbox render captured
# at GPX parse time) for every card that shows one: the library grid, the
# calendar sidebar, the mobile week cards and the friends page. Mirrors
# AvatarsController: ActiveStorage's default blob URL 302s to a 5-minute
# signed disk URL, which defeats browser caching inside fragment-cached cards
# — this endpoint streams the blob itself and stamps a year-long immutable
# cache on the response, so each thumb is fetched exactly once. The URL is
# keyed by the blob's signed_id, so a regenerated image lands on a new URL
# and stale bytes are impossible. Public by capability token: the public
# calendar share renders thumbs to anonymous visitors.
class StaticMapsController < ApplicationController
  skip_before_action :authenticate_user!

  def show
    blob = ActiveStorage::Blob.find_signed(params[:signed_id])
    raise ActiveRecord::RecordNotFound unless blob

    # Route static-map blobs only: this endpoint can never be tricked into
    # streaming a GPX (or any other attachment) by crafting a signed id.
    unless ActiveStorage::Attachment.exists?(blob_id: blob.id, record_type: "Route", name: "static_map")
      raise ActiveRecord::RecordNotFound
    end

    # Signed ids are immutable, so the payload can be cached aggressively.
    # `immutable` additionally tells the browser it never needs to revalidate:
    # zero requests until the image (and with it the URL) changes.
    response.headers["Cache-Control"] = "public, max-age=#{1.year.to_i}, immutable"

    send_data blob.download,
              filename: blob.filename.to_s,
              type: blob.content_type.presence || "image/png",
              disposition: "inline"
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    head :not_found
  end
end
