class AllowDailyBriefRecipeRevisions < ActiveRecord::Migration[8.1]
  def up
    add_index :ai_runs, %i[site_id report_on recipe_version], unique: true, nulls_not_distinct: true,
      where: "kind = 'brief'", name: "one_ai_brief_per_day_and_recipe"
    remove_index :ai_runs, name: "one_ai_brief_per_day"
  end

  def down
    if select_value("SELECT 1 FROM ai_runs WHERE kind = 'brief' GROUP BY site_id, report_on HAVING COUNT(*) > 1 LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "Saved brief revisions have separate usage receipts."
    end
    add_index :ai_runs, %i[site_id report_on], unique: true, where: "kind = 'brief'", name: "one_ai_brief_per_day"
    remove_index :ai_runs, name: "one_ai_brief_per_day_and_recipe"
  end
end
