class AddOwnerChoiceToActionDrafts < ActiveRecord::Migration[8.1]
  def change
    add_column :action_drafts, :owner_choice, :string
    add_column :action_drafts, :owner_choice_note, :string, limit: 1000
    add_check_constraint :action_drafts, "owner_choice IN ('keep_preferred', 'prefer_ranking')", name: "action_draft_owner_choice_valid"
  end
end
