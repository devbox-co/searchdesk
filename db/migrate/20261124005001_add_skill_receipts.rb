class AddSkillReceipts < ActiveRecord::Migration[8.1]
  def change
    add_column :action_drafts, :input_snapshot, :jsonb, null: false, default: {}
    add_column :wording_runs, :skill_version, :string, default: "business_wording/v1", null: false
  end
end
