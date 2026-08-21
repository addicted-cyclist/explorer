class CreateRoutes < ActiveRecord::Migration[7.2]
  def change
    create_table :routes do |t|
      t.references :user, null: false, foreign_key: true
      t.string :title
      t.text :description
      t.float :distance
      t.float :elevation_gain
      t.float :elevation_loss
      t.float :min_elevation
      t.float :max_elevation
      t.integer :duration
      t.string :source
      t.string :google_drive_file_id

      t.timestamps
    end
  end
end
