module SeoWorkflows
  class WeeklyReviewEvidence
    def initialize(site:, start:, day:, now:)
      @site, @start, @day, @now = site, start, day, now
    end

    def self.full_weeks(range)
      range.select { |day| day.sunday? && range.cover?(day - 6) }.map(&:iso8601)
    end

    def feeds
      sources = @site.source_snapshots.where(observed_on: @start..@now.in_time_zone(@site.time_zone).to_date)
        .where("metrics->>'host' = ? AND metrics->>'kind' = 'review_activity'", @site.host)
        .order(observed_on: :desc, id: :desc)
      imported = sources.where(provider: EvidenceImport::PROVIDER).limit(20).map do |source|
        source.metrics.fetch("records", []).index_by { |week| week.fetch("week_ending") }
          .transform_values { |week| week.merge("snapshot_id" => source.id) }
      end
      captured = sources.where(provider: [LocalSeoData::Collection::PROVIDER, LocalSeoData::DataForSeoCollection::PROVIDER])
        .where("metrics->>'state' = 'captured' AND metrics->>'scope_digest' IS NOT NULL")
        .where("metrics->>'period_on' BETWEEN ? AND ?", @start.iso8601, @day.iso8601).limit(80)
      feeds = captured.group_by { |source| [source.provider, source.metrics["scope_digest"]] }.values.map do |snapshots|
        snapshots.reverse_each.each_with_object({}) do |source, weeks|
          source.metrics.fetch("records", []).each do |week|
            weeks[week.fetch("week_ending")] = week.merge("snapshot_id" => source.id) if week["complete_coverage"]
          end
        end
      end
      feeds + imported
    end
  end
end
