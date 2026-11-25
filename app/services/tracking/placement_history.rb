module Tracking
  class PlacementHistory
    def self.for_slots(slots)
      return {} if slots.empty?

      source = RankObservation.joins(:daily_slot)
        .where(source: "dataforseo", daily_slots: {tracking_series_id: slots.map(&:tracking_series_id).uniq, day: ..slots.map(&:day).max})
        .where("evidence->?->>'method' = ? AND evidence->?->>'status' IN ('ranked', 'outside')",
          GooglePlacement::KEY, GooglePlacement::METHOD, GooglePlacement::KEY)
        .select("daily_slots.tracking_series_id AS series_id", "daily_slots.id AS slot_id", "daily_slots.day AS day",
          "rank_observations.evidence->'#{GooglePlacement::KEY}' AS reading")

      # A profile change starts a new comparison period, including when a
      # previously used profile is reconnected after tracking a different one.
      changes = RankObservation.from(source, :readings).select(<<~SQL.squish)
        readings.*, CASE WHEN ARRAY[reading->>'place_id', reading->>'profile_cid'] IS DISTINCT FROM
          LAG(ARRAY[reading->>'place_id', reading->>'profile_cid']) OVER (PARTITION BY series_id ORDER BY day)
          THEN 1 ELSE 0 END AS scope_changed
      SQL
      segments = RankObservation.from(changes, :changes).select(<<~SQL.squish)
        changes.*, SUM(scope_changed) OVER (PARTITION BY series_id ORDER BY day) AS scope_period
      SQL
      result = <<~SQL.squish
        SELECT slot_id, day, reading, LAG(day) OVER history AS previous_day, LAG(reading) OVER history AS previous_reading,
          FIRST_VALUE(day) OVER history AS baseline_day, FIRST_VALUE(reading) OVER history AS baseline_reading
        FROM (#{segments.to_sql}) segments
        WINDOW history AS (PARTITION BY series_id, scope_period ORDER BY day)
      SQL
      rows = RankObservation.from("(#{result}) placements")
        .where("placements.slot_id IN (?)", slots.map(&:id))
        .pluck("placements.slot_id", "placements.day", "placements.reading", "placements.previous_day", "placements.previous_reading",
          "placements.baseline_day", "placements.baseline_reading")
      rows.to_h do |id, day, current, previous_day, previous, baseline_day, baseline|
        current, previous, baseline = [current, previous, baseline].map { |value| value.is_a?(String) ? JSON.parse(value) : value }
        [id, { current: current, previous: comparison(previous_day, previous, current),
          baseline: comparison(baseline_day, baseline, current, starting: baseline_day == day) }]
      end
    end

    def self.comparison(day, earlier, current, starting: false)
      return unless earlier

      change = earlier["position"] - current["position"] if !starting && earlier["position"] && current["position"]
      state = if starting then :baseline
      elsif change&.positive? then :up
      elsif change&.negative? then :down
      elsif change == 0 then :unchanged
      elsif current["position"] then :entered
      elsif earlier["position"] then :left
      else :outside_both
      end
      { day: day.to_date, position: earlier["position"], change: change, transition: state,
        type_changed: earlier["type"] && current["type"] && earlier["type"] != current["type"] }
    end
    private_class_method :comparison
  end
end
