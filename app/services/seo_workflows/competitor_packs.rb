module SeoWorkflows
  class CompetitorPacks
    include Rails.application.routes.url_helpers

    def self.scope(site)
      RankObservation.provider_for(site)
        .where("jsonb_exists(rank_observations.evidence, ?)", Tracking::GoogleLocalPack::KEY)
    end

    def initialize(site, start, day, comparison_start: start.prev_month, period: "monthly")
      @site, @start, @day = site, start, day
      @comparison_start, @period = comparison_start, period
    end

    def rows
      captures = self.class.latest_samples(@site, @start..@day).limit(20)
      series_ids = captures.map(&:pack_series_id)
      return [] if series_ids.empty?

      prior = self.class.latest_samples(@site, @comparison_start...@start).where(tracking_series: { id: series_ids }).index_by(&:pack_series_id)
      captures.map do |capture|
        earlier = prior[capture.pack_series_id]
        current = data(capture)
        text = "#{capture.pack_keyword} · #{capture.pack_market} · #{capture.pack_device} · #{capture.pack_day}."
        if current["listings"].any?
          prefix = complete?(current) ? "Sampled top three" : "Identified listings in partial sample"
          text += " #{prefix}: #{current.fetch('listings').pluck('name').join(', ')}."
        else
          text += " No identifiable unpaid local pack listings were returned."
        end
        compared = earlier && complete?(current) && complete?(data(earlier))
        if compared
          text += comparison(data(earlier), current, earlier.pack_day)
        else
          text += " Two complete #{@period} samples are required for comparison."
          text += " This capture can serve as the baseline for the next reporting period." if complete?(current) && !earlier
        end
        { "source" => "DataForSEO · Google local pack", "text" => text,
          "path" => competitor_capture_seo_workflows_path(capture_id: capture.id),
          "baseline_path" => compared ? competitor_capture_seo_workflows_path(capture_id: earlier.id) : nil }.compact
      end
    end

    def self.latest_samples(site, range)
      scope(site).merge(TrackingSeries.current).where(daily_slots: { day: range })
        .select(Arel.sql(<<~SQL.squish))
          DISTINCT ON (tracking_series.id) rank_observations.*,
          tracking_series.id AS pack_series_id, daily_slots.day AS pack_day,
          tracking_series.device AS pack_device, tracking_series.settings->>'location' AS pack_market,
          keywords.phrase AS pack_keyword
        SQL
        .order("tracking_series.id", "daily_slots.day DESC")
    end

    private

    def data(capture)
      capture.evidence.fetch(Tracking::GoogleLocalPack::KEY)
    end

    def complete?(sample) = sample["coverage"] == "top_three"

    def comparison(before, after, old_day)
      baseline = before.fetch("listings")
      current = after.fetch("listings")
      old = baseline.index_by { |item| item.fetch("cid") }
      new = current.index_by { |item| item.fetch("cid") }
      entered = (new.keys - old.keys).map { |cid| new.fetch(cid).fetch("name") }
      departed = (old.keys - new.keys).map { |cid| old.fetch(cid).fetch("name") }
      notes = [" Compared with #{old_day}."]
      notes << " New in the sampled top three: #{entered.join(', ')}." if entered.any?
      notes << " Left the sampled top three: #{departed.join(', ')}." if departed.any?
      notes << " Same three listings sampled." if entered.empty? && departed.empty?
      current.each_with_index do |item, index|
        cid = item.fetch("cid")
        previous = old[cid]
        next unless previous

        changes = []
        old_index = old.keys.index(cid)
        changes << "position #{old_index + 1} to #{index + 1}" if old_index != index
        %w[reviews rating].each do |field|
          if previous.key?(field) && item.key?(field) && previous[field] != item[field]
            changes << "#{field} #{previous[field]} to #{item[field]}"
          end
        end
        if previous["paid_seen"] != item["paid_seen"]
          changes << (item["paid_seen"] ? "sponsored listing observed in this sample" : "no matching sponsored listing observed in this sample")
        end
        notes << " #{item.fetch('name')}: #{changes.join(', ')}." if changes.any?
      end
      notes.join
    end
  end
end
