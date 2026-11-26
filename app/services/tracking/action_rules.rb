module Tracking
  class ActionRules
    def self.call(observation)
      series = observation.tracking_series
      if observation.position && observation.preferred_url.present? && !ResultUrl.same_page?(observation.preferred_url, observation.winning_url)
        record(series, observation, "page_match", "Check which page answers this search",
          "Compare the observed page with the preferred page and confirm which one best answers the search before editing it.")
      end
      baseline = series.baseline_observation
      return unless baseline&.position && observation.position && baseline.day < observation.day
      return unless observation.position - baseline.position >= 3
      prior = series.rank_observations.comparable.joins(:daily_slot).where(daily_slots: { day: observation.day - 1 }).first
      return unless prior&.position && prior.position - baseline.position >= 3
      record(series, observation, "rank_drop", "Review two lower daily positions",
        "The observed rank was at least three positions below its starting point on two consecutive days. Check matching search and page evidence before making a change.",
        "baseline_observation_id" => baseline.id, "previous_observation_id" => prior.id)
    end

    def self.record(series, observation, kind, title, description, additional = {})
      action = series.keyword_actions.find_or_initialize_by(kind: kind)
      return if action.persisted? && action.observed_on > observation.day
      action.update!(title: title, description: description, observed_on: observation.day,
        evidence: additional.merge("observation_id" => observation.id, "source" => observation.source,
          "winning_url" => observation.winning_url, "preferred_url" => observation.preferred_url,
          "position" => observation.position, "rule_version" => 1, "series_id" => series.id))
    end
  end
end
