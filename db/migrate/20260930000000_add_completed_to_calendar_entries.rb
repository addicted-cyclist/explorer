class AddCompletedToCalendarEntries < ActiveRecord::Migration[7.2]
  def change
    # Per-entry completion: many entries can reference one route, and each
    # ride is done (or not) on its own. routes.completed stays as the
    # library's aggregate Done badge — CalendarsController#toggle_completed
    # syncs it one-way (entry → route, never back).
    add_column :calendar_entries, :completed, :boolean, default: false, null: false
  end
end
