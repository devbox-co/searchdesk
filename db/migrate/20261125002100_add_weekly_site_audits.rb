class AddWeeklySiteAudits < ActiveRecord::Migration[8.1]
  def change
    add_column :sites, :weekly_site_audit_enabled, :boolean, default: false, null: false
    add_column :site_audits, :trigger_kind, :string, default: "manual", null: false
  end
end
