module SeoWorkflows
  class DedicatedLsaReport
    include Rails.application.routes.url_helpers

    COVERAGE = {
      "no_ads_returned" => "The provider returned no ads in this sample.",
      "no_verified_match" => "No returned row matched the configured business name and phone.",
      "ambiguous" => "Multiple returned rows matched the configured business name and phone."
    }.freeze

    def initialize(site, period)
      @site, @period = site, period
    end

    def rows
      current = captured(@period)
      return [] unless current

      sample = current.metrics
      text = "#{sample.fetch('query')} · #{sample.fetch('market')} · collected #{current.observed_on}. "
      text += if sample["coverage"] == "matched"
        "Matched listing at position #{sample.fetch('listing_position')} in #{sample.fetch('ad_rows')} returned ads."
      else
        COVERAGE.fetch(sample.fetch("coverage"))
      end
      previous = captured(@period - 7)
      comparable = previous && current.observed_on > previous.observed_on &&
        previous.metrics.values_at("scope_digest", "sandbox") == sample.values_at("scope_digest", "sandbox") &&
        previous.metrics["coverage"] == "matched" && sample["coverage"] == "matched"
      alert = false
      if comparable
        detail, alert = movement(previous, current)
        text += detail
      else
        text += " A comparable position from the previous week is unavailable."
      end
      label = sample["sandbox"] ? "Local SEO Data · dedicated LSA sandbox" : "Local SEO Data · dedicated LSA scan"
      [{ "source" => label, "text" => text, "path" => source_snapshot_path(current),
        "baseline_path" => comparable ? source_snapshot_path(previous) : nil, "attention" => alert && !sample["sandbox"] }.compact]
    end

    private

    def captured(day)
      snapshot = LocalSeoData::Collection.receipt(@site, "M4", day)
      snapshot if snapshot && snapshot.metrics["host"] == @site.host && snapshot.metrics["state"] == "captured"
    end

    def movement(previous, current)
      old = previous.metrics.fetch("listing_position")
      new_position = current.metrics.fetch("listing_position")
      delta = new_position - old
      text = " Previous sample on #{previous.observed_on}: position #{old}."
      alert = false
      if old <= 3 && new_position > 3
        text += " The listing moved outside the top three."
        alert = true
      elsif delta >= 3
        text += " The listing dropped #{delta} positions."
        alert = true
      end
      entrants = new_competitors(previous.metrics, current.metrics)
      if entrants.any?
        text += " New in the sampled top three: #{entrants.join(', ')}."
        alert = true
      end
      [text, alert]
    end

    def new_competitors(previous, current)
      old = previous["top_three"]
      new = current["top_three"]
      return [] unless old && new

      previous_ids = old.pluck("id").to_set
      new.filter_map { |row| row.fetch("name") unless row["tracked"] || previous_ids.include?(row.fetch("id")) }
    end
  end
end
