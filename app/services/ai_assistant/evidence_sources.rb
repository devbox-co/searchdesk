module AiAssistant
  module EvidenceSources
    private

    def source_unavailable(label, path, consent:)
      reason = consent ? "No eligible saved readings for this scope through #{@day}." : "Sharing with the assistant is off for this site."
      fact("#{label} · #{reason}", "Source availability", path)
    end

    def search_dashboard
      @search_dashboard ||= SearchConsole::PositionDashboard.new(site: @site, requested_day: @day)
    end

    def read_weekly_clicks
      if !@brief && @question.match?(/\b(mobile|desktop|tablet)\b/)
        fact("The saved weekly search comparison combines all devices. A device-specific weekly comparison is unavailable.",
          "Source availability", search_console_path)
        return
      end
      if @setting.share_google && (grant = @access.grant("gsc"))
        selected = for_terms(search_dashboard.rows) { |row| row[:keyword].phrase }.pluck(:keyword)
        keywords = selected.uniq { |keyword| keyword.phrase.downcase }
        result = search_dashboard.weekly_clicks(keywords)
      end
      unless result
        source_unavailable("Weekly search clicks", search_console_path, consent: @setting.share_google) unless @brief
        return
      end

      finish, changes = result.values_at(:finish, :changes)
      market = @site.rank_country_code == "GB" ? "UK" : @site.rank_country_code
      parts = ["#{market} Google web search, all devices. Comparing #{finish - 13} to #{finish - 7} with #{finish - 6} to #{finish}, " \
        "#{changes.size} of #{pluralize(keywords.size, "tracked search")} had reported click counts on all 14 days."]
      loss = changes.min_by { |row| row[:delta] }
      gain = changes.max_by { |row| row[:delta] }
      examples = []
      examples << loss if loss && loss[:delta].negative?
      examples << gain if gain && gain[:delta].positive?
      examples.each do |row|
        phrase = clean(row[:keyword].phrase).truncate(130)
        direction = row[:delta].positive? ? "rose" : "fell"
        parts << "“#{phrase}” #{direction} from #{row[:previous]} to #{row[:current]} clicks."
      end
      parts << if changes.empty?
        "Wait for two weeks of complete readings before comparing the tracked searches."
      elsif examples.empty?
        "Weekly clicks held steady for every search with complete readings."
      else
        "Check whether the change persists before editing a page."
      end
      url = source_snapshots_path(provider: "gsc", q: "daily-position-", keyword: keywords.one? ? keywords.first.phrase : nil)
      fact(parts.join(" "), "Weekly search clicks", url, sources: ["google"], grants: {"gsc" => grant},
        keywords: selected.map(&:id), snapshots: result[:snapshot_ids])
    end

    def read_google_search
      consent = @setting.share_google
      size = @facts.size
      if consent
        grant = @access.grant("gsc")
        gsc_totals(grant) if grant
        dashboard = search_dashboard
        rows = for_terms(dashboard.rows) { |row| row[:keyword].phrase }
        rows.select { |r| r[:current] || r[:latest] }.first(3).each do |row|
          reading = row[:current] || row[:latest]
          record = reading[:record]
          live = reading[:basis] == "final_api"
          next if live && grant.nil?
          position = reading[:position] ? "average position #{reading[:position].round(2)}" : "no measured average position"
          basis = live ? "final API" : "imported report"
          clicks = reading[:clicks].nil? ? "click count unavailable" : "#{reading[:clicks]} clicks"
          text = "#{clean(row[:keyword].phrase)}, #{reading[:date]}, #{dashboard.country}, Google web search, all devices, #{basis} — " \
            "#{position}, #{reading[:impressions]} impressions and #{clicks}."
          refs = [record.id]
          baseline = row[:baseline]
          if baseline && baseline[:date] < reading[:date] && (baseline[:basis] != "final_api" || grant)
            live ||= baseline[:basis] == "final_api"
            refs << baseline[:record].id
            text += " First measured average was #{baseline[:position].round(2)} on #{baseline[:date]}."
          end
          text += " No comparable reading on #{@day}." if reading[:date] < @day
          fact(text, "Google Search Console", source_snapshot_path(record), sources: ["google"],
            snapshots: refs, grants: live ? {"gsc" => grant} : {})
        end
      end
      source_unavailable("Search Console", search_console_path, consent:) if size == @facts.size
    end

    def gsc_totals(grant)
      connection = @site.search_console_connection
      history = connection.search_console_reports.where(property: connection.property, period_end: ..@day).order(period_end: :desc).first
      return unless history
      %w[current previous].each do |period_key|
        period = history.report[period_key]
        next unless period.is_a?(Hash) && valid_period?(period)
        m = period["metrics"]
        text = m ? "#{m['clicks']} clicks and #{m['impressions']} impressions" : "no matching rows"
        fact("Google web search, all countries and devices, #{period['start']} through #{period['end']} recorded #{text}.",
          "Google Search Console", search_console_path, sources: ["google"], grants: {"gsc" => grant}, search_reports: [history.id])
      end
    end

    def read_traffic
      consent = @setting.share_google
      size = @facts.size
      grant = @access.grant("ga4") if consent
      if grant
        connection = @site.analytics_connection
        # Use the snapshots from the binding used by the sync. An old property,
        # re-used stream, imported analytics file or lookalike host cannot match.
        host_id = Digest::SHA256.hexdigest(@site.host).first(24)
        id_prefix = "ga4-google-organic-v1-#{connection.property_id}-#{host_id}-"
        scope = SourceSnapshot.visible_for(@site).where(provider: "Google Analytics 4", observed_on: ..@day)
          .where("external_id LIKE ?", "#{ActiveRecord::Base.sanitize_sql_like(id_prefix)}%")
          .where("metrics->>'property_id' = ?", connection.property_id)
        scope = scope.where("metrics->'stream_ids' @> ?::jsonb AND metrics->'stream_ids' <@ ?::jsonb",
          connection.stream_ids.to_json, connection.stream_ids.to_json)
        latest = scope.order(observed_on: :desc).first
        if latest && valid_period?(latest.metrics)
          # Daily syncs create overlapping rolling windows. Only present the
          # adjacent non-overlapping period alongside the latest observation.
          previous = scope.find_by(observed_on: Date.iso8601(latest.metrics["start"]) - 1)
          [latest, previous].compact.each { |s| ga4_period(s, grant) }
          if previous && valid_period?(previous.metrics)
            now = latest.metrics.dig("metrics", "sessions")
            before = previous.metrics.dig("metrics", "sessions")
            if now.is_a?(Integer) && before.is_a?(Integer)
              movement = now == before ? "unchanged" : "#{(now - before).abs} #{now > before ? 'higher' : 'lower'}"
              fact("Google organic sessions were #{movement} in the 28 days through #{latest.observed_on} (#{now}) compared with the preceding 28 days through #{previous.observed_on} (#{before}).",
                "Google Analytics 4", source_snapshot_path(latest), sources: ["google"], grants: {"ga4" => grant}, snapshots: [latest.id, previous.id])
            end
          end
        end
      end
      source_unavailable("Google Analytics 4", analytics_path, consent:) if size == @facts.size
    end

    def ga4_period(snapshot, grant)
      period = snapshot.metrics
      return unless valid_period?(period) && period["end"] == snapshot.observed_on.iso8601
      m = period["metrics"]
      metrics = m ? "#{m['sessions']} sessions, #{m['engaged_sessions']} engaged sessions. Key events are unvalidated as enquiries" : "no matching rows"
      caveat = " Google flagged sampling, thresholds or aggregation limits." if period.values_at("subject_to_thresholding", "sampled", "data_loss_from_other_row").any?
      fact("Google / organic traffic for #{@site.host}, #{period['start']} through #{period['end']} recorded #{metrics}.#{caveat}",
        "Google Analytics 4", source_snapshot_path(snapshot), sources: ["google"], grants: {"ga4" => grant}, snapshots: [snapshot.id])
    end

    def valid_period?(p)
      from, through = %w[start end].map { |key| Date.iso8601(p.fetch(key)) }
      through <= @day && through - from == 27
    rescue Date::Error, TypeError, KeyError
      false
    end

    def read_maps
      size = @facts.size
      consent = @setting.share_maps
      if consent
        grant = @access.grant("falcon")
        LocalFalcon::MapsSummary.latest(@site, through: @day, keywords: @terms).first(3).each do |scan|
          s = scan.snapshot
          next if s.observed_on > @day || !scan.grid_size
          live = s.source_path.blank? && s.metrics["place_id"].present?
          next if live && (!grant || s.metrics["place_id"] != @site.local_falcon_connection.place_id)
          parts = ["#{clean(s.keyword)}, Google Maps scan for #{clean(@site.location)} on #{s.observed_on}, #{scan.grid_size}×#{scan.grid_size} grid."]
          parts << "Radius #{scan.radius.join(' ')}." if scan.radius
          parts << "Share of local voice #{scan.share}%." if scan.share
          parts << "Top three on #{scan.top_three_counts.join(' of ')} pins." if scan.top_three_counts
          if (pair = scan.comparisons.first)
            parts << "Compared with #{pair[:date]} on #{pair[:pins]} matched pins, gained top-three on #{pair[:gained]} and lost it on #{pair[:lost]}."
          end
          fact(parts.join(" "), "Local Falcon", source_snapshot_path(s), sources: ["maps"],
            grants: live ? {"falcon" => grant} : {}, snapshots: [s.id])
        end
        read_business_profile(grant) if grant && @setting.share_google
      end
      source_unavailable("Local Falcon Maps", local_falcon_connection_path, consent:) if size == @facts.size
    end

    def read_business_profile(grant)
      s = SourceSnapshot.visible_for(@site).linked_gbp_cache.where(observed_on: ..@day).first
      return unless s && s.metrics["place_id"] == @site.local_falcon_connection.place_id && valid_period?(s.metrics)
      counts = s.metrics["totals"]
      return unless counts.is_a?(Hash)
      values = {"WEBSITE_CLICKS" => "website clicks", "CALL_CLICKS" => "call clicks", "BUSINESS_DIRECTION_REQUESTS" => "direction requests"}.filter_map do |key, label|
        count = Integer(counts[key], exception: false)
        "#{count} #{label}" if count && count >= 0
      end
      return if values.empty?
      fact("Business Profile interactions, #{s.metrics['start']} through #{s.metrics['end']} included #{values.join(', ')}. Qualified enquiries are unverified.",
        "Google Business Profile via Local Falcon", source_snapshot_path(s), sources: %w[maps google], grants: {"falcon" => grant},
        snapshots: [s.id], expires_at: s.updated_at + 29.days)
    end

    def read_campaign
      consent = @setting.share_semrush
      size = @facts.size
      if consent
        dashboard = Semrush::CampaignDashboard.new(site: @site, requested_day: @day)
        rows = for_terms(dashboard.rows) { |row| row[:term] }
        rows.select { |r| r[:latest] }.first(3).each do |row|
          r = row[:current] || row[:latest]
          baseline = row[:baseline]
          scope = dashboard.selected
          position = r[:rank] ? "position #{r[:rank]}" : "no reported position"
          text = "#{clean(row[:term])}, #{r[:date]}, #{clean(scope[:location])}, #{scope[:device]} — #{position} in Semrush's feature-inclusive campaign."
          text += " Reported feature was #{clean(r[:feature])}." if r[:feature].present?
          text += " Numeric baseline #{baseline[:rank]} on #{baseline[:date]}." if baseline&.dig(:rank)
          text += " No capture on #{@day}." unless row[:current]
          fact(text, "Semrush Position Tracking", source_snapshot_path(r[:record]), sources: ["semrush"],
            snapshots: [r[:record].id, baseline&.dig(:record)&.id].compact)
        end
      end
      source_unavailable("Semrush Position Tracking", integrations_path, consent:) if size == @facts.size
    end
  end
end
