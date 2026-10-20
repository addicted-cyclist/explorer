# frozen_string_literal: true

require "test_helper"

# email verification end to end (technote.FEATURES.md):
# * legacy (soft) accounts keep browsing with the dismissable modal and get
#   their first code emailed lazily on the visit that shows it;
# * new (hard) accounts are bounced from every app page to the standalone
#   gate until a live code verifies them;
# * verify / resend (1-minute server throttle) / change-email all funnel
#   through EmailVerificationController.
class EmailVerificationControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  setup do
    # Unverified by design: this suite exercises the hard gate and the code
    # modal, so the default verified user from valid_user_attributes won't do.
    @user = User.create!(valid_user_attributes(email_verified_at: nil))
  end

  teardown { travel_back }

  # ---- Soft (legacy) flow ---------------------------------------------------

  test "legacy unverified user sees the dismissable modal over the app" do
    sign_in make_legacy_user

    get routes_path

    assert_response :success
    assert_includes response.body, "verify-email-modal"
    assert_includes response.body, "Verify later"
  end

  test "verified users never see the modal" do
    legacy = User.create!(valid_user_attributes(email: "legacyok@example.com")
                                        .merge(email_verification_soft: true))
    assert_predicate legacy, :email_verified?
    sign_in legacy

    get routes_path

    assert_response :success
    assert_not_includes response.body, "verify-email-modal"
  end

  test "the 24h snooze cookie hides the modal and pauses the code emails" do
    user = make_legacy_user
    sign_in user
    cookies["email_verification_snoozed"] = "1"

    assert_emails 0 do
      get routes_path
    end

    assert_response :success
    assert_not_includes response.body, "verify-email-modal"
    # Nothing was minted either: with the modal hidden nothing promises a
    # code, so none is sent until the snooze lapses and the modal (with its
    # lazy send) returns.
    assert user.reload.verification_code_digest.blank?
  end

  test "legacy user's first page view emails their code (lazy send)" do
    user = make_legacy_user
    sign_in user

    assert_emails 1 do
      get routes_path
    end
    assert user.reload.verification_code_digest.present?

    # The code is fresh — browsing on does not re-send.
    assert_emails 0 do
      get calendar_path
    end
  end

  test "a stale legacy code is re-sent on the next page view" do
    user = make_legacy_user
    sign_in user
    get routes_path

    travel 11.minutes

    assert_emails 1 do
      get calendar_path
    end
  end

  # ---- Hard gate ------------------------------------------------------------

  test "hard unverified user is bounced to the gate from app pages" do
    sign_in @user

    get routes_path

    assert_redirected_to email_verification_gate_path
    follow_redirect!
    assert_response :success
    assert_includes response.body, "Verify your email address"
    # No escape hatches on the hard gate; sign-out stays reachable.
    assert_not_includes response.body, "Verify later"
    assert_includes response.body, "Sign out"
  end

  test "sign out from the gate ends the session instead of bouncing back" do
    sign_in @user

    # What the gate's Sign out button actually sends: a POST carrying the
    # _method=delete override (Rack rewrites it to DELETE before routing).
    post destroy_user_session_path, params: { _method: "delete" }
    assert_response :redirect
    assert_not_includes response.redirect_url, "email_verification"

    follow_redirect! # → unauthenticated root: the landing, not the gate
    assert_response :success
    assert_not_includes response.body, "Verify your email address"

    # The session is really gone: app pages ask for sign-in again.
    get routes_path
    assert_redirected_to new_user_session_path
  end

  test "verified users are never bounced" do
    @user.update_columns(email_verified_at: Time.current)
    sign_in @user

    get routes_path

    assert_response :success
    assert_not_includes response.body, "verify-email-modal"
  end

  test "verifying from the gate unlocks the app" do
    sign_in @user
    code = @user.generate_email_verification_code!

    post email_verification_verify_path, params: { code: code }

    # authenticated_root_path ("/" — routes#index for signed-in users).
    assert_redirected_to authenticated_root_path
    assert_predicate @user.reload, :email_verified?
    follow_redirect!
    assert_response :success
    assert_not_includes response.body, "verify-email-modal"
  end

  test "wrong codes bounce with an in-modal error and exhaust after five tries" do
    sign_in @user
    code = @user.generate_email_verification_code!

    5.times do
      post email_verification_verify_path, params: { code: wrong_code(code) }
      follow_redirect!
      # (apostrophe-free substring: "doesn't" is HTML-escaped in the body)
      assert_includes response.body, "Check the email and try again"
    end

    # Even the correct code is dead until a fresh one is requested.
    post email_verification_verify_path, params: { code: code }
    follow_redirect!
    assert_includes response.body, "Too many incorrect attempts"
    assert_not_predicate @user.reload, :email_verified?
  end

  test "verify rejects an expired code" do
    sign_in @user
    code = @user.generate_email_verification_code!

    travel 11.minutes

    post email_verification_verify_path, params: { code: code }

    follow_redirect!
    assert_includes response.body, "expired"
    assert_not_predicate @user.reload, :email_verified?
  end

  test "resend is throttled to one code per minute" do
    sign_in @user
    @user.generate_email_verification_code!
    old_digest = @user.reload.verification_code_digest

    assert_emails 0 do
      post email_verification_resend_path
    end
    follow_redirect!
    assert_includes response.body, "Please wait"

    travel 61.seconds

    assert_emails 1 do
      post email_verification_resend_path
    end
    assert_not_equal old_digest, @user.reload.verification_code_digest
  end

  test "changing the email from the modal re-issues the code to the new address" do
    sign_in @user
    @user.generate_email_verification_code!

    assert_emails 1 do
      post email_verification_update_email_path, params: { email: "moved@example.com" }
    end
    assert_equal "moved@example.com", @user.reload.email
    assert_not_predicate @user, :email_verified?
    assert @user.verification_code_digest.present?
  end

  test "an invalid new email bounces with the validation message" do
    sign_in @user

    assert_emails 0 do
      post email_verification_update_email_path, params: { email: "not-an-email" }
    end
    follow_redirect!
    assert_includes response.body, "Email is invalid"
    # The invalid change never reached the database (current_user shares the
    # in-memory object, so assert against the reloaded record).
    assert_equal "rider@example.com", @user.reload.email
  end

  test "changing to an email another account uses is rejected" do
    User.create!(valid_user_attributes(email: "taken@example.com"))
    sign_in @user

    assert_emails 0 do
      post email_verification_update_email_path, params: { email: "taken@example.com" }
    end
    follow_redirect!
    assert_includes response.body, "already been taken"
  end

  # ---- Sign-up trigger ---------------------------------------------------------

  test "sign-up emails the first code and lands on the gate" do
    assert_emails 1 do
      post user_registration_path, params: {
        user: { first_name: "Nora", last_name: "Nova", username: "noranova",
                email: "nora@example.com", password: "password123",
                password_confirmation: "password123" }
      }
    end

    assert_response :redirect
    follow_redirect! # → authenticated root…
    assert_redirected_to email_verification_gate_path # …but the gate catches it
    follow_redirect!
    assert_response :success
    assert_includes response.body, "Verify your email address"

    nora = User.find_by!(email: "nora@example.com")
    assert_not_predicate nora, :email_verified?
    assert nora.verification_code_digest.present?
  end

  test "sign-in of an unverified hard user still works, then gates" do
    post user_session_path, params: { user: { email: @user.email, password: "password123" } }

    assert_response :redirect
    get routes_path

    assert_redirected_to email_verification_gate_path
  end

  private

  def make_legacy_user
    User.create!(valid_user_attributes(email: "legacy#{@user.id}@example.com")
                        .merge(email_verification_soft: true, email_verified_at: nil))
  end

  # Any well-formed 6-digit string different from +code+.
  def wrong_code(code)
    code == "000000" ? "999999" : "000000"
  end
end
