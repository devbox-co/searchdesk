class ActionDraft < ApplicationRecord
  belongs_to :keyword_action

  def self.capture!(action)
    version, steps = SeoSkills::ActionReview.for(action.kind)
    return unless steps

    inputs = snapshot(action)
    create_or_find_by!(keyword_action: action, skill_version: version, input_digest: digest(inputs)) do |draft|
      draft.input_snapshot = inputs
      draft.instructions = steps
    end
  end

  def self.current_for(action)
    version, steps = SeoSkills::ActionReview.for(action.kind)
    return unless steps

    action.action_drafts.find_by(skill_version: version, input_digest: digest(snapshot(action)))
  end

  def self.snapshot(action)
    series = action.tracking_series
    {
      "kind" => action.kind, "observed_on" => action.observed_on.iso8601,
      "phrase" => series.settings.fetch("keyword"), "device" => series.device,
      "location" => series.settings.fetch("location"),
      "evidence" => action.evidence.slice("source", "observation_id", "baseline_observation_id",
        "previous_observation_id", "preferred_url", "winning_url", "position", "series_id", "rule_version").sort.to_h
    }
  end

  def self.digest(input)
    Digest::SHA256.hexdigest(JSON.generate(input))
  end
end
