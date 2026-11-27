class CreateSeoWorkflowNotifications < ActiveRecord::Migration[8.1]
  def change
    add_column :sites, :seo_workflow_rollup_enabled, :boolean, null: false, default: false
    add_reference :sites, :seo_workflow_email_owner, foreign_key: { to_table: :users, on_delete: :nullify }

    create_table :seo_workflow_notifications do |t|
      t.references :seo_workflow_run, null: false, foreign_key: { on_delete: :cascade }
      t.references :recipient, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :kind, null: false
      t.string :email_status, null: false, default: "off"
      t.datetime :email_attempted_at
      t.datetime :email_sent_at
      t.timestamps
      t.index [:seo_workflow_run_id, :kind], unique: true, name: "index_seo_workflow_notifications_on_event"
      t.index [:email_status, :id]
    end
  end
end
