# email verification (technote.FEATURES.md): the 6-digit code modal.
# New accounts are hard-gated — GET /email_verification is the only page they
# can load, rendered in the bare verification_gate layout so no app shell
# leaks past the wall. Legacy (soft) accounts reach the same modal inside
# the app layout, so the verify / resend / change-email posts serve both
# surfaces and every action skips the gate itself.
class EmailVerificationController < ApplicationController
  skip_before_action :require_email_verification!

  def gate
    redirect_to authenticated_root_path if current_user.email_verified?
    # The bare verification_gate layout — no app shell may leak past the wall.
    render layout: "verification_gate"
  end

  def verify
    result = current_user.verify_email_code!(code_param)
    if result == :ok
      # A parked public-share join (parked while the account was still
      # hard-gated) completes now, landing on the shared week with its
      # confirmation flash; otherwise straight into the app. Not
      # redirect_back: a hard user posts from the gate, and bouncing "back"
      # would re-render the gate.
      target = complete_pending_public_join
      if target
        redirect_to target
      else
        redirect_to authenticated_root_path,
                    notice: "Your email has been verified. Welcome aboard!"
      end
    else
      redirect_back fallback_location: email_verification_gate_path,
                    flash: { verification_alert: verification_error_message(result) }
    end
  end

  # Server-side resend throttle: one code per minute (the client countdown
  # is seeded from the same cooldown the model enforces).
  def resend
    left = current_user.email_code_cooldown_left
    return resend_throttled(left) if left.positive?

    current_user.deliver_verification_code
    redirect_back fallback_location: email_verification_gate_path,
                  flash: { verification_notice: "A new code is on its way to #{current_user.email}." }
  end

  # Change the address from the modal, then re-issue the code to it. The
  # model callback un-verifies on the change, keeping the gate honest.
  def update_email
    if current_user.update(email: params[:email].to_s.strip)
      current_user.deliver_verification_code
      redirect_back fallback_location: email_verification_gate_path,
                    flash: { verification_notice: "Code sent to #{current_user.email}." }
    else
      redirect_back fallback_location: email_verification_gate_path,
                    flash: { verification_alert: current_user.errors.full_messages.to_sentence }
    end
  end

  private

  # The six boxes post as code[]; both shapes arrive as a joined string here.
  def code_param
    params[:code].is_a?(Array) ? params[:code].join : params[:code].to_s
  end

  def resend_throttled(seconds_left)
    redirect_back fallback_location: email_verification_gate_path,
                  flash: { verification_alert: "Please wait #{seconds_left} seconds before requesting another code." }
  end

  def verification_error_message(result)
    {
      invalid: "That code doesn't match. Check the email and try again.",
      expired: "That code has expired — request a new one below.",
      exhausted: "Too many incorrect attempts — request a new code below."
    }.fetch(result, "That code doesn't match. Check the email and try again.")
  end
end
