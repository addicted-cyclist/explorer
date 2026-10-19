# email verification: delivers the 6-digit code behind the
# verify-email modal (design-refs/stitch_explorer_v0.12). Sent synchronously
# like Devise's own mail (Resend SMTP in production, tmp/mails in development).
class UserMailer < ApplicationMailer
  def verification_code(user, code)
    @user = user
    @code = code
    mail(to: user.email, subject: "#{code} is your Explorer verification code")
  end
end
