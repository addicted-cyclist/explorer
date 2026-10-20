# frozen_string_literal: true

require "test_helper"

# the verification email delivers the 6-digit code to the user's
# address, from Devise's configured sender, in both HTML and text parts.
class UserMailerTest < ActionMailer::TestCase
  test "verification_code emails the code from the Devise sender" do
    user = User.create!(valid_user_attributes(email: "verifyme@example.com"))

    mail = UserMailer.verification_code(user, "024680")

    assert_emails(1) { mail.deliver_now }
    assert_equal [ user.email ], mail.to
    assert_equal [ Devise.mailer_sender ], mail.from
    assert_match(/\b024680\b/, mail.text_part.body.to_s)
    assert_match(/\b024680\b/, mail.html_part.body.to_s)
    assert_match(/10 minutes/, mail.text_part.body.to_s)
  end
end
