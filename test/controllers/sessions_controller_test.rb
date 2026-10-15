# frozen_string_literal: true

require "test_helper"
require "time"

# Session lifetime coverage for the mobile logout bug (technote.BUGS.md).
# The cookie store now persists the session for 30 days of inactivity
# (config/initializers/session_store.rb), paired with Devise's :timeoutable
# (config.timeout_in). Browser-session cookies die when mobile Chrome or
# Firefox close, so the session cookie must carry an explicit expiry that
# slides with activity, and the server must re-check the same horizon.
class SessionsControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @user = User.create!(valid_user_attributes)
  end

  teardown { travel_back }

  # ---- The mobile logout bug: the cookie must outlive the browser ---------

  test "sign in sets a persistent session cookie that outlives the browser" do
    sign_in_via_form @user

    # Success redirects (a failed attempt renders 422 per Devise's Hotwire
    # responder config), and the user really is signed in afterwards.
    assert_response :redirect
    get routes_path
    assert_response :success

    cookie = session_set_cookie
    assert cookie, "_explorer_session must be set on sign in"
    # A fresh sign-in gets the full 30-day horizon, so closing the browser
    # (mobile Chrome/Firefox) can no longer drop the login.
    assert_in_delta 30.days.from_now, cookie_expiry, 5.minutes
  end

  test "cookie expiry slides with activity" do
    sign_in_via_form @user
    travel 29.days

    get routes_path

    assert_response :success
    # The cookie is re-sent on the request, re-anchoring its expiry to
    # "now" — an active rider is never asked to sign in again.
    assert_in_delta 30.days.from_now, cookie_expiry, 5.minutes
  end

  # ---- Auto logout: 30 days without any request ends the session ----------

  test "session times out after 30 days without activity" do
    sign_in_via_form @user
    travel 30.days + 1.minute

    get routes_path

    assert_redirected_to new_user_session_path
  end

  test "sign out still ends the session" do
    sign_in_via_form @user

    delete destroy_user_session_path

    assert_response :redirect
    get routes_path
    assert_redirected_to new_user_session_path
  end

  private

  # Real sign-in through Devise's sessions controller (not the sign_in test
  # helper, which injects the Warden session directly and skips writing
  # timeoutable's last_request_at marker).
  def sign_in_via_form(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end

  # Raw Set-Cookie header of the session cookie from the last response
  # (the cookie jar keeps only the value, not the expiry attributes).
  def session_set_cookie
    Array(response.headers["Set-Cookie"]).grep(/_explorer_session=/).first
  end

  def cookie_expiry
    Time.httpdate(session_set_cookie[/expires=([^;]+)/i, 1])
  end
end
