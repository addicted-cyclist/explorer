# frozen_string_literal: true

require "test_helper"

# email verification OTP behavior (technote.FEATURES.md): code
# generation stores only a peppered digest, verification accepts the live
# code within its TTL, attempts are budgeted, the resend cooldown ticks and
# an email change un-verifies the account.
class UserEmailVerificationTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    # Unverified: this suite exercises the OTP lifecycle itself.
    @user = User.create!(valid_user_attributes(email_verified_at: nil))
  end

  teardown { travel_back }

  # ---- Gate mode flags -----------------------------------------------------

  test "new users are hard-gated and unverified" do
    assert_not_predicate @user, :email_verified?
    assert_not_predicate @user, :email_verification_soft?
    assert_predicate @user, :email_verification_hard?
  end

  test "legacy users carry the soft flag" do
    legacy = User.create!(valid_user_attributes(email: "legacy@example.com")
                                        .merge(email_verification_soft: true))

    assert_predicate legacy, :email_verification_soft?
    assert_not_predicate legacy, :email_verification_hard?
  end

  # ---- Code generation -----------------------------------------------------

  test "generate_email_verification_code! returns a 6-digit code and stores only its digest" do
    code = @user.generate_email_verification_code!

    assert_match(/\A\d{6}\z/, code)
    assert @user.verification_code_digest.present?
    assert_not_equal code, @user.verification_code_digest
    assert_not_equal Digest::SHA256.hexdigest(code), @user.verification_code_digest
    assert_in_delta Time.current, @user.verification_code_sent_at, 1.second
    assert_equal 0, @user.verification_code_attempts
    assert_not_predicate @user, :email_code_stale?
  end

  test "codes are always six digits, zero-padded" do
    codes = Array.new(20) { @user.generate_email_verification_code! }

    assert codes.all? { |candidate| candidate.match?(/\A\d{6}\z/) }
    # Randomness sanity: 20 draws out of 10^6 should never collide.
    assert_equal codes.uniq.length, codes.length
  end

  # ---- Verification ----------------------------------------------------------

  test "verify_email_code! accepts the live code and marks the account verified" do
    code = @user.generate_email_verification_code!

    assert_equal :ok, @user.verify_email_code!(code)
    assert_predicate @user.reload, :email_verified?
    assert_nil @user.verification_code_digest
    assert_nil @user.verification_code_sent_at
    assert_equal 0, @user.verification_code_attempts
  end

  test "verify_email_code! rejects a wrong code and counts the attempt" do
    code = @user.generate_email_verification_code!

    assert_equal :invalid, @user.verify_email_code!(wrong_code(code))
    assert_equal 1, @user.reload.verification_code_attempts
    assert_not_predicate @user, :email_verified?
    # The code stays live: a typo can be corrected within the same code.
    assert_equal :ok, @user.verify_email_code!(code)
  end

  test "verify_email_code! is exhausted after five bad attempts" do
    code = @user.generate_email_verification_code!

    5.times { assert_equal :invalid, @user.verify_email_code!(wrong_code(code)) }

    assert_equal :exhausted, @user.verify_email_code!(code)
    assert_not_predicate @user.reload, :email_verified?
    assert_predicate @user, :email_code_stale?
  end

  test "verify_email_code! expires the code after ten minutes" do
    code = @user.generate_email_verification_code!

    travel 11.minutes

    assert_equal :expired, @user.verify_email_code!(code)
    assert_not_predicate @user.reload, :email_verified?
  end

  test "verify_email_code! rejects malformed input" do
    @user.generate_email_verification_code!

    assert_equal :invalid, @user.verify_email_code!(nil)
    assert_equal :invalid, @user.verify_email_code!("12a45")
    assert_equal :invalid, @user.verify_email_code!("1234")
    assert_equal :invalid, @user.verify_email_code!("1234567")
  end

  test "verify_email_code! with no code sent reports expired" do
    assert_equal :expired, @user.verify_email_code!("123456")
  end

  # ---- Staleness + cooldown ---------------------------------------------------

  test "email_code_stale? covers fresh, expired, exhausted and missing codes" do
    assert_predicate @user, :email_code_stale? # nothing sent yet

    code = @user.generate_email_verification_code!
    assert_not_predicate @user, :email_code_stale?

    travel 11.minutes
    assert_predicate @user, :email_code_stale? # past the TTL
    travel_back

    @user.update_columns(verification_code_attempts: User::EMAIL_CODE_MAX_ATTEMPTS)
    assert_predicate @user, :email_code_stale? # attempt budget burned
  end

  test "email_code_cooldown_left counts down the resend throttle" do
    @user.generate_email_verification_code!

    # Delta-based: the µs round trip through the DB makes exact boundary
    # values flaky (ceil of 30.0000001 is 31).
    assert_in_delta User::EMAIL_CODE_RESEND_COOLDOWN, @user.email_code_cooldown_left, 1

    travel 30.seconds
    assert_in_delta 30, @user.email_code_cooldown_left, 1

    travel 31.seconds
    assert_equal 0, @user.email_code_cooldown_left
  end

  # ---- Email change -----------------------------------------------------------

  test "changing the email un-verifies the account and drops the code" do
    code = @user.generate_email_verification_code!
    @user.update!(email_verified_at: Time.current)
    @user.update!(email: "moved@example.com")

    assert_nil @user.reload.email_verified_at
    assert_nil @user.verification_code_digest
    assert_nil @user.verification_code_sent_at
    assert_equal 0, @user.verification_code_attempts
    # The old code no longer verifies anything — a fresh one goes out.
    assert_equal :expired, @user.verify_email_code!(code)
  end

  private

  # Any well-formed 6-digit string different from +code+.
  def wrong_code(code)
    code == "000000" ? "999999" : "000000"
  end
end
