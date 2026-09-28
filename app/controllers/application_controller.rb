class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Sign-in is required app-wide by default (Devise). Screens that must be
  # reachable without an account opt out explicitly with
  # skip_before_action:
  #   * PagesController#landing   — marketing root for signed-out visitors
  #   * PublicCalendarController  — read-only /c/:token shares
  # Devise's own controllers (sessions, registrations, passwords) do not
  # inherit from ApplicationController, so they are unaffected.
  before_action :authenticate_user!

  # Devise's sign-in landing. A guest bounced off a public share's Join has
  # its intent parked in session (PublicCalendarController#join) — finish
  # the join now and land on the shared week with the ride marked "Joined".
  # Sign-up funnels through the same hook (Devise's after_sign_up_path_for
  # delegates here), so a fresh account joins without a second click.
  def after_sign_in_path_for(resource)
    pending = session.delete(:pending_public_join).to_h.symbolize_keys
    return super if pending.blank?

    owner = User.find_by(public_token: pending[:token])
    raise ActiveRecord::RecordNotFound unless owner&.calendar_public?

    joined_entry = CalendarEntry.join_ride!(owner.calendar_entries.find(pending[:entry_id]), owner: resource)
    flash[:notice] = "You joined \"#{joined_entry.route.title}\" — it is on your calendar for " \
                     "#{joined_entry.scheduled_on.strftime('%b %-d')}."
    public_calendar_path(owner.public_token, week: pending[:week].presence)
  rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid
    # The share died (made private) or the entry vanished meanwhile: drop
    # the intent and land on the share link like any other visitor.
    public_calendar_path(pending[:token], week: pending[:week].presence)
  end
end
