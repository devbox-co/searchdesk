class RecordTrackingAttemptsAndPageAssignments < ActiveRecord::Migration[8.1]
  def change
    add_column :daily_slots, :attempt_key, :string
    add_index :daily_slots, :attempt_key, unique: true, where: "attempt_key IS NOT NULL"
    create_table :keyword_page_assignments do |t|
      t.references :keyword, null: false, foreign_key: true
      t.date :effective_on, null: false
      t.string :url
      t.timestamps
    end
    add_index :keyword_page_assignments, [:keyword_id, :effective_on], unique: true
  end
end
