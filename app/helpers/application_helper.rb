module ApplicationHelper
  # Phase 12 — profile avatar. Renders the uploaded image when the user has
  # one (cropped by CSS `object-fit: cover`; no image_processing variants),
  # otherwise the initials block used everywhere else in the app. The caller
  # supplies the sized round wrapper (e.g. .account-avatar--lg or the header
  # chip); this helper only fills it.
  #
  # The img points at the cacheable /avatars/:signed_id endpoint instead of
  # ActiveStorage's default blob URL: that one 302-redirects to a 5-minute
  # signed disk URL, so the browser re-requested the photo on every page
  # view. The endpoint stamps a year-long immutable cache on the response and
  # is keyed by blob, so a re-upload rotates the URL — each avatar is fetched
  # from the server exactly once and staleness is impossible.
  def user_avatar(user)
    if user_avatar_attached?(user)
      image_tag user_avatar_path(user.avatar.blob.signed_id),
                class: "account-avatar__img", alt: ""
    else
      tag.span calendar_initials(user), class: "account-avatar__initials", "aria-hidden": true
    end
  end

  # True only for a persisted avatar attachment: a failed save leaves an
  # unsaved in-memory attachment behind, whose blob has no signed_id yet —
  # it must render (and behave) exactly like "no avatar".
  def user_avatar_attached?(user)
    attachment = user.avatar.attachment
    attachment.present? && attachment.persisted?
  end

  # The route thumb <img> for every card that shows one (library grid,
  # calendar sidebar, mobile week cards, friends cards), or nil when the
  # route has no static map — callers render their fallback icon instead.
  # The img points at the cacheable /route_thumbs/:signed_id endpoint instead
  # of ActiveStorage's default blob URL, for the same reason as the avatar
  # above: the default 302s to a 5-minute signed disk URL, so fragment-cached
  # cards would re-request the image on every render. The endpoint stamps a
  # year-long immutable cache and is keyed by blob, so a regenerated image
  # rotates the URL — each thumb is fetched from the server exactly once and
  # staleness is impossible.
  #
  # Same persisted-attachment guard as the avatar: a failed parse/save leaves
  # an unsaved in-memory attachment whose blob has no signed_id yet.
  def route_static_map_thumb(route, css_class)
    attachment = route.static_map.attachment
    return unless attachment.present? && attachment.persisted?

    image_tag route_static_map_path(attachment.blob.signed_id),
              class: css_class, alt: "", loading: "lazy", draggable: false
  end
end
