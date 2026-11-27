class AddLinkCheckToActionDrafts < ActiveRecord::Migration[8.1]
  def change
    change_table :action_drafts do |t|
      t.jsonb :link_check_result, default: {}, null: false
      t.datetime :link_checked_at
      t.datetime :link_check_started_at
    end
  end
end
