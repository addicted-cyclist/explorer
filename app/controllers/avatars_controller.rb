# frozen_string_literal: true

# Cacheable avatar serving for every place user_avatar renders (header chip,
# calendar pips, account page). ActiveStorage's default blob URL 302s to a
# 5-minute signed disk URL, which defeats browser caching: each page view
# re-requested the photo. This endpoint streams the blob itself and stamps a
# year-long immutable cache on the response — the browser fetches each avatar
# exactly once, then answers every repeat view from its own cache with zero
# requests back to ActiveStorage.
#
# The URL is keyed by the blob's signed_id, so a re-upload lands on a new URL
# and stale bytes are impossible (same contract as GpxFilesController, whose
# signed-id streaming this mirrors). Public by capability token: the public
# calendar renders the owner's avatar pip to anonymous visitors.
class AvatarsController < ApplicationController
  skip_before_action :authenticate_user!

  def show
    blob = ActiveStorage::Blob.find_signed(params[:signed_id])
    raise ActiveRecord::RecordNotFound unless blob

    # Avatar blobs only: every one of them passed the User model's
    # JPG/PNG/WebP validation on attach, so this endpoint can never be
    # tricked into streaming a different attachment (or a non-image payload)
    # by crafting a signed id for it.
    unless ActiveStorage::Attachment.exists?(blob_id: blob.id, record_type: "User", name: "avatar")
      raise ActiveRecord::RecordNotFound
    end

    # Signed ids are immutable, so the payload can be cached aggressively.
    # `immutable` additionally tells the browser it never needs to revalidate:
    # zero requests until the avatar (and with it the URL) changes.
    response.headers["Cache-Control"] = "public, max-age=#{1.year.to_i}, immutable"

    send_data blob.download,
              filename: blob.filename.to_s,
              type: blob.content_type.presence || "image/jpeg",
              disposition: "inline"
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    head :not_found
  end
end
