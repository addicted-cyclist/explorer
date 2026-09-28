# Phase 9 — account settings. Ships the profile summary and the public
# calendar share controls (the calendar_public toggle feeding the
# ensure_public_token callback). Phase 11 extends this page with the full
# profile/password editors and account deletion.
class AccountsController < ApplicationController
  def show
  end

  # Only the share toggle is writable for now; the permit list grows with
  # the full account page (Phase 11).
  def update
    if current_user.update(account_params)
      redirect_to account_path, notice: share_notice
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

  def account_params
    params.require(:user).permit(:calendar_public)
  end

  def share_notice
    if current_user.calendar_public?
      "Your calendar is public — anyone with the share link can view it."
    else
      "Your calendar is private — existing share links no longer work."
    end
  end
end
