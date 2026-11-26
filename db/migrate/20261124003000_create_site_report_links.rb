class CreateSiteReportLinks < ActiveRecord::Migration[8.0]
  def change
    create_table :site_report_links do |t|
      t.references :site, null: false, foreign_key: { on_delete: :cascade }
      t.string :provider, null: false, limit: 48
      t.string :url, null: false, limit: 512
      t.timestamps
    end
    add_index :site_report_links, [:site_id, :provider], unique: true
  end
end
