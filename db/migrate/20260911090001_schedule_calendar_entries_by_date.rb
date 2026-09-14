# Calendar entries are pinned to concrete calendar dates (the route detail
# page schedules via a month grid; the Phase 7 weekly grid and the public
# calendar both query by date ranges). day_of_week recurring entries were
# never used and are replaced by scheduled_on.
class ScheduleCalendarEntriesByDate < ActiveRecord::Migration[7.2]
  def change
    remove_column :calendar_entries, :day_of_week, :integer
    add_column :calendar_entries, :scheduled_on, :date
    add_index :calendar_entries, [ :user_id, :scheduled_on ]
  end
end
