# Persist the session cookie for 30 days of inactivity: a browser-session
# cookie dies when mobile browsers (Chrome/Firefox) are closed, logging
# users out. expire_after slides on every request, so active riders are
# never asked to sign in again; after 30 quiet days the cookie expires
# server-side via Devise's matching timeout_in.
Rails.application.config.session_store :cookie_store,
  key: "_explorer_session",
  expire_after: 30.days,
  secure: Rails.env.production? # HTTPS-only cookies in production (force_ssl)
