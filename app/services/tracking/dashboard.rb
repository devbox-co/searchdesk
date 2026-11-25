module Tracking
  class Dashboard
    def self.rows(site:, date:, device:, include_placement: false)
      day = date.to_date
      scope = TrackingSeries.joins(:keyword).where(keywords: { site_id: site.id })
      scope = scope.where(device: device) if device.present? && device != "all"
      series_list = scope.includes(:keyword, :keyword_actions, baseline_observation: :daily_slot).order("keywords.priority DESC, keywords.phrase ASC", :device).to_a
      series_list = series_list.group_by { |series| [series.keyword_id, series.device] }.values.filter_map do |versions|
        versions.select { |s| s.enrolled_on <= day && (s.archived_at.nil? || s.date_in_zone(s.archived_at) >= day) }
          .max_by { |s| [s.enrolled_on, s.id] } || versions.find { |s| s.archived_at.nil? }
      end
      slots = DailySlot.where(tracking_series_id: series_list.map(&:id), day: day).includes(:rank_observation).index_by(&:tracking_series_id)
      placements = include_placement ? PlacementHistory.for_slots(slots.values) : {}
      last_dates = DailySlot.where(tracking_series_id: series_list.map(&:id), status: %w[ranked outside]).where(day: ..day).group(:tracking_series_id).maximum(:day)
      series_list.map do |series|
        slot = slots[series.id]
        result = slot&.rank_observation
        first = series.baseline_observation
        baseline = first if first && first.day <= day
        status = result&.status || slot&.status
        status = series.paused ? "paused" : (day < series.date_in_zone ? "missing" : "pending") if status.blank?
        status = "missing" if status == "pending" && day < series.date_in_zone
        status = "not_enrolled" if day < series.enrolled_on
        change = baseline.position - result.position if baseline&.position && result&.position && baseline.day < day
        comparison = transition(baseline, result, change)
        { keyword: series.keyword, series: series, slot: slot, observation: result, baseline: baseline,
          rank: result&.position, baseline_rank: baseline&.position, change: change, transition: comparison,
          status: status, winning_url: result&.winning_url, actions: series.keyword_actions.select { |a| a.status == "open" && a.observed_on <= day },
          as_of: last_dates[series.id], placement: placements[slot&.id] }
      end
    end

    def self.transition(first, current, change)
      return :unavailable unless first && current && current.status != "incomplete"
      return :baseline if first.id == current.id
      return :up if change&.positive?
      return :down if change&.negative?
      return :unchanged if change == 0
      return :entered if current.position
      return :left if first.position
      :outside_both
    end
  end
end
