class AddOriginEntryToCalendarEntries < ActiveRecord::Migration[7.2]
  def change
    add_column :calendar_entries, :origin_entry_id, :bigint
    add_index :calendar_entries, :origin_entry_id
    # Self-referential link to the friend's ride this entry was joined from.
    # on_delete: :nullify keeps my joined copy alive if the friend unschedules;
    # the cleared link just makes the dock offer Join again.
    add_foreign_key :calendar_entries, :calendar_entries,
                    column: :origin_entry_id, on_delete: :nullify
  end
end
