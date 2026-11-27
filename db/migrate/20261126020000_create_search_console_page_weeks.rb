class CreateSearchConsolePageWeeks < ActiveRecord::Migration[8.1]
  def change
    create_table :search_console_page_weeks do |t|
      t.references :site, null: false, foreign_key: {on_delete: :cascade}
      t.string :property, null: false
      t.string :country, null: false, limit: 3
      t.string :query, null: false
      t.string :device, null: false
      t.date :week_start, null: false
      t.jsonb :pages, null: false, default: []
      t.integer :clicks, limit: 8
      t.integer :impressions, limit: 8
      t.boolean :partial, null: false, default: false
      t.timestamps
      t.index %i[site_id property country query device week_start], unique: true, name: "unique_search_console_page_week"
    end

    change_table :search_console_connections do |t|
      t.string :page_week_sync_key
      t.datetime :page_week_attempted_at
      t.datetime :page_week_synced_at
      t.string :page_week_error
    end
  end
end
