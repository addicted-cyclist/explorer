# Phase 9 shipped the public-calendar share controls; Phase 12 turns the page
# into the full account settings: profile editor (first/last name, username;
# the email is only editable while unverified), avatar upload (Active Storage,
# JPG/PNG/WebP ≤ 5 MB), a Devise-rules
# password change and account deletion with the dependent: :destroy cascade.
# The connected-accounts section stays display-only for now.
class AccountsController < ApplicationController
  before_action :set_minimum_password_length, only: %i[show]

  def show
  end

  # Two different posters land here: the share-toggle form (Phase 9, only
  # :calendar_public) and the profile editor (+ the avatar quick-form). The
  # notice adapts so the toggle keeps its established share messages.
  def update
    # An email change drops any outstanding code (reset_email_verification)
    # but does not email a fresh one here: a profile save is not a
    # verification action, and a snoozed ("Verify later") legacy user asked
    # not to be nagged. The lazy send re-issues a fresh code on the next
    # visit that actually shows the verification modal. (The modal's own
    # change-email form — EmailVerificationController#update_email — does
    # re-issue immediately: that user is actively verifying.)
    if current_user.update(account_params)
      redirect_to account_path, notice: update_notice
    else
      @failed_section = :profile
      render :show, status: :unprocessable_entity
    end
  end

  # Password change follows Devise's own rules (validatable: 6..128 chars,
  # confirmation) and requires the current password as authorisation.
  def update_password
    if current_user.update_with_password(password_params)
      # Refresh the session credential so the user stays signed in.
      bypass_sign_in(current_user)
      redirect_to account_path, notice: "Your password has been changed."
    else
      @failed_section = :password
      set_minimum_password_length
      render :show, status: :unprocessable_entity
    end
  end

  # Synchronous purge: avatars are tiny (≤ 5 MB) and determinism in tests
  # beats shaving a queued job.
  def remove_avatar
    current_user.avatar.purge
    redirect_to account_path, notice: "Your avatar has been removed."
  end

  # Cascades through routes, calendar entries and both friendship directions
  # (the dependent: :destroy associations), which also invalidates the public
  # share link and drops the Drive tokens.
  def destroy
    current_user.destroy!
    sign_out(current_user)
    redirect_to unauthenticated_root_path, notice: "Your account has been deleted."
  end

  private

  def account_params
    # A verified address is the confirmed identity and must not be swappable
    # to an unverified one, so :email is dropped for verified users (the
    # disabled field never posts one anyway). Unverified users keep the edit
    # — fixing a typo'd address is exactly how they get verified.
    permitted = %i[first_name last_name username calendar_public avatar]
    permitted << :email unless current_user.email_verified?
    params.require(:user).permit(*permitted)
  end

  def password_params
    params.require(:user).permit(:current_password, :password, :password_confirmation)
  end

  # Toggle-only posts keep the share notices (Phase 9 behaviour); everything
  # else — profile fields or an avatar upload — reads as a profile save.
  def update_notice
    return share_notice if params[:user].key?(:calendar_public)

    "Your profile has been updated."
  end

  def share_notice
    if current_user.calendar_public?
      "Your calendar is public — anyone with the share link can view it."
    else
      "Your calendar is private — existing share links no longer work."
    end
  end

  def set_minimum_password_length
    @minimum_password_length = Devise.password_length.min
  end
end
