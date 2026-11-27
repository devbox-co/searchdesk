class LinkAiRunsToSiteFindings < ActiveRecord::Migration[8.1]
  def change
    add_reference :ai_runs, :site_finding, foreign_key: {on_delete: :nullify}
    add_column :ai_runs, :page_advice_digest, :string, limit: 64
  end
end
