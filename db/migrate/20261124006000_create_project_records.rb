class CreateProjectRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :source_snapshots do |t|
      t.references :site, null: false, foreign_key: { on_delete: :cascade }
      t.string :provider, null: false
      t.string :external_id, null: false
      t.string :title, null: false
      t.date :observed_on, null: false
      t.text :scope, null: false
      t.jsonb :metrics, null: false, default: {}
      t.text :source_url
      t.text :source_path
      t.string :keyword
      t.timestamps
      t.index [:site_id, :provider, :external_id], unique: true
      t.index [:site_id, :observed_on]
    end

    create_table :project_tasks do |t|
      t.references :site, null: false, foreign_key: { on_delete: :cascade }
      t.string :external_id, null: false
      t.string :title, null: false
      t.string :status, null: false
      t.string :priority, null: false
      t.text :summary
      t.text :source_path
      t.string :working_status
      t.text :owner_note
      t.timestamps
      t.index [:site_id, :external_id], unique: true
    end
  end
end
