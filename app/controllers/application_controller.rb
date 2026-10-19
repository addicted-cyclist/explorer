class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Sign-in is required app-wide by default (Devise). Screens that must be
  # reachable without an account opt out explicitly with
  # skip_before_action:
  #   * PagesController#landing   — marketing root for signed-out visitors
  #   * PublicCalendarController  — read-only /c/:token shares
  # Devise's controllers DO inherit from here (DeviseController's superclass
  # is this class), so the session endpoints run these filters too — see
  # require_email_verification! for the sign-out exemption that keeps the
  # gate's escape hatch working.
  before_action :authenticate_user!

  # email verification (technote.FEATURES.md). Hard gate: accounts
  # created after the feature shipped may not load any app page until the
  # 6-digit code confirms the address — every request bounces to the
  # standalone gate page. Legacy accounts (email_verification_soft, see the
  # migration) keep browsing with the dismissable modal rendered in the
  # layout instead. EmailVerificationController opts out of both checks via
  # skip_before_action, and Devise's session endpoints are exempt inside
  # require_email_verification! so Sign out on the gate stays reachable.
  before_action :require_email_verification!

  # The soft modal says "We've sent a code" — make that true for legacy
  # users whose code is missing, expired or exhausted: mint + email one on
  # the visit that shows the modal. Only real document navigations count —
  # GET requests that are not Turbo Frame bodies (stream requests are always
  # POSTs in this app, so request.get? already excludes them). Hard users
  # got theirs at sign-up and re-request via the gate's resend button.
  before_action :maybe_send_soft_verification_code

  # Devise's sign-in landing. A guest bounced off a public share's Join has
  # its intent parked in session (PublicCalendarController#join) — finish
  # the join now and land on the shared week with the ride marked "Joined".
  # Sign-up funnels through the same hook (Devise's after_sign_up_path_for
  # delegates here), so a fresh account joins without a second click —
  # except when the new account is hard-gated: the parked intent then
  # completes right after the address is verified
  # (EmailVerificationController#verify), so the gate never eats its
  # confirmation flash.
  def after_sign_in_path_for(resource)
    return super if resource.is_a?(User) && resource.email_verification_hard? && !resource.email_verified?

    complete_pending_public_join || super
  end

  private

  # Finish a parked public-share join and return the shared-week path — or
  # nil when nothing is parked. The intent is dropped when the share died
  # meanwhile (made private) or the entry vanished.
  def complete_pending_public_join
    pending = session[:pending_public_join].to_h.symbolize_keys
    return nil if pending.blank?

    owner = User.find_by(public_token: pending[:token])
    raise ActiveRecord::RecordNotFound unless owner&.calendar_public?

    joined_entry = CalendarEntry.join_ride!(owner.calendar_entries.find(pending[:entry_id]), owner: current_user)
    session.delete(:pending_public_join)
    flash[:notice] = "You joined \"#{joined_entry.route.title}\" — it is on your calendar for " \
                     "#{joined_entry.scheduled_on.strftime('%b %-d')}."
    public_calendar_path(owner.public_token, week: pending[:week].presence)
  rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid
    # The share died (made private) or the entry vanished meanwhile: drop
    # the intent and land on the share link like any other visitor.
    session.delete(:pending_public_join)
    public_calendar_path(pending[:token], week: pending[:week].presence)
  end

  # The hard gate. Signed-in, unverified, non-legacy: nothing of the
  # app may render, so redirect to the bare gate page (no layout escapes).
  # Devise's session endpoints run this filter too (DeviseController
  # subclasses ApplicationController) and must stay open: Sign out is the
  # gate's only escape hatch — gating destroy would 302 it straight back to
  # the gate, leaving the account trapped signed in. Sign-in and sign-up
  # pass anyway (the visitor is not signed in when the filter runs);
  # passwords and registrations stay behind the wall.
  def require_email_verification!
    return if is_a?(Devise::SessionsController)
    return if !user_signed_in? || current_user.email_verified? || current_user.email_verification_soft?

    redirect_to email_verification_gate_path
  end

  # lazy first code for legacy (soft) accounts. Only real document
  # navigations (GET, not Turbo Frame bodies) show the modal, so only those
  # trigger the send; the fresh digest keeps later requests from re-sending.
  # Snoozed ("Verify later") visits render no modal — nothing is promised,
  # so nothing is emailed — and the send resumes when the snooze lapses.
  def maybe_send_soft_verification_code
    return unless user_signed_in?
    return if current_user.email_verified? || !current_user.email_verification_soft?
    return if cookies[:email_verification_snoozed].present?
    return unless current_user.email_code_stale?
    return unless request.get? && !turbo_frame_request?

    current_user.deliver_verification_code
  end
end
