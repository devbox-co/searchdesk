class CreateSeoWorkflowReportDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :seo_workflow_report_deliveries do |t|
      t.references :seo_workflow_run, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.references :requested_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.text :recipient, null: false
      t.string :status, null: false, default: "preview"
      t.datetime :attempted_at
      t.datetime :sent_at
      t.timestamps
      t.index [:status, :id]
    end
  end
end
