class CreateFriendships < ActiveRecord::Migration[7.2]
  def change
    create_table :friendships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :friend, null: false, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "accepted"
      t.timestamps
    end

    add_index :friendships, [ :user_id, :friend_id ], unique: true
    add_check_constraint :friendships, "user_id <> friend_id", name: "friendships_not_self"
  end
end
