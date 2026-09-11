class AddLibraryFieldsToRoutes < ActiveRecord::Migration[7.2]
  def change
    add_column :routes, :tier, :string
    add_column :routes, :sport_type, :string
    add_column :routes, :completed, :boolean, default: false, null: false
    add_column :routes, :track_svg, :text
  end
end
