class CreateSkillRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :action_drafts do |t|
      t.references :keyword_action, null: false, foreign_key: { on_delete: :cascade }
      t.string :skill_version, null: false
      t.string :input_digest, null: false
      t.jsonb :instructions, null: false
      t.timestamps
      t.index [:keyword_action_id, :skill_version, :input_digest], unique: true, name: "unique_action_draft_input"
    end
    create_table :wording_settings do |t|
      t.references :site, null: false, index: {unique: true}, foreign_key: {on_delete: :cascade}
      t.text :phrases, null: false, default: ""
      t.boolean :enabled, null: false, default: false
      t.string :revision, null: false
      t.timestamps
    end
    create_table :wording_runs do |t|
      t.references :wording_setting, null: false, foreign_key: {on_delete: :cascade}
      t.string :revision, null: false
      t.string :status, null: false, default: "pending"
      t.string :model
      t.datetime :attempted_at
      t.integer :choice
      t.timestamps
      t.index [:wording_setting_id, :revision], unique: true
    end
  end
end
