class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Sign-in is required app-wide by default (Devise). Screens that must be
  # reachable without an account opt out explicitly with
  # skip_before_action:
  #   * PagesController#landing   — marketing root for signed-out visitors
  #   * PublicCalendarController  — read-only /c/:token shares (phase 7)
  # Devise's own controllers (sessions, registrations, passwords) do not
  # inherit from ApplicationController, so they are unaffected.
  before_action :authenticate_user!
end
