class CreateKeywordTracking < ActiveRecord::Migration[8.1]
  def change
    add_column :sites, :rank_location_code, :integer

    create_table :keywords do |t|
      t.references :site, null: false, foreign_key: true
      t.string :phrase, null: false
      t.string :preferred_url
      t.integer :priority, null: false, default: 0
      t.timestamps
    end
    add_index :keywords, [:site_id, :phrase], unique: true

    create_table :tracking_series do |t|
      t.references :keyword, null: false, foreign_key: true
      t.string :device, null: false
      t.string :source, null: false
      t.jsonb :settings, null: false, default: {}
      t.string :fingerprint, null: false
      t.date :enrolled_on, null: false
      t.boolean :paused, null: false, default: false
      t.datetime :archived_at
      t.bigint :baseline_observation_id
      t.timestamps
    end
    add_index :tracking_series, [:keyword_id, :device], unique: true, where: "archived_at IS NULL"

    create_table :daily_slots do |t|
      t.references :tracking_series, null: false, foreign_key: true
      t.date :day, null: false
      t.string :status, null: false, default: "pending"
      t.string :reason
      t.string :task_id
      t.datetime :attempted_at
      t.datetime :last_queued_at
      t.datetime :retry_after
      t.integer :poll_attempts, null: false, default: 0
      t.timestamps
    end
    add_index :daily_slots, [:tracking_series_id, :day], unique: true
    add_index :daily_slots, :task_id, unique: true, where: "task_id IS NOT NULL"
    add_index :daily_slots, [:status, :retry_after]

    create_table :rank_observations do |t|
      t.references :daily_slot, null: false, foreign_key: true, index: { unique: true }
      t.datetime :captured_at, null: false
      t.string :status, null: false
      t.integer :position
      t.integer :preferred_position
      t.string :winning_url
      t.string :preferred_url
      t.integer :coverage, null: false
      t.string :source, null: false
      t.jsonb :evidence, null: false, default: {}
      t.timestamps
    end
    add_foreign_key :tracking_series, :rank_observations, column: :baseline_observation_id, on_delete: :nullify

    create_table :keyword_actions do |t|
      t.references :tracking_series, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :title, null: false
      t.text :description, null: false
      t.string :status, null: false, default: "open"
      t.date :observed_on, null: false
      t.jsonb :evidence, null: false, default: {}
      t.timestamps
    end
    add_index :keyword_actions, [:tracking_series_id, :kind], unique: true
  end
end
