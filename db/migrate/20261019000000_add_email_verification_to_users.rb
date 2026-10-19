class AddEmailVerificationToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :email_verified_at, :datetime
    add_column :users, :verification_code_digest, :string
    add_column :users, :verification_code_sent_at, :datetime
    add_column :users, :verification_code_attempts, :integer, default: 0, null: false

    # Hard/soft gate discriminator (technote.FEATURES.md): accounts created
    # after the feature ships are hard-gated (default false) — every app page
    # bounces to the standalone verify gate until the address is confirmed.
    add_column :users, :email_verification_soft, :boolean, default: false, null: false

    reversible do |dir|
      dir.up do
        # Everyone who already had an account keeps browsing with the
        # dismissable modal (soft) instead of hitting the wall (hard).
        User.reset_column_information
        User.update_all(email_verification_soft: true)
      end
    end
  end
end
