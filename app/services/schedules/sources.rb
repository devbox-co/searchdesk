module Schedules
  class Sources
    include Rails.application.routes.url_helpers

    def initialize(site:, now:)
      @site = site
      @now = now
    end

    def rows
      search = @site.search_console_connection
      analytics = @site.analytics_connection
      falcon = @site.local_falcon_connection
      search_import = import_row("search-console", "Google Search Console", search, search_console_path,
        scope_ready: SearchConsole::Client.matches?(search&.property, @site.host),
        operator_ready: SearchConsole::Client.configured?, attempt: search&.sync_started_at)
      [
        search_import, competing_pages_row(search, search_import),
        import_row("analytics", "Google Analytics 4", analytics, analytics_path,
          scope_ready: analytics&.property_id.present? && analytics&.verified_host == @site.host,
          operator_ready: Analytics::Client.configured?, attempt: analytics&.sync_started_at),
        import_row("local-falcon", "Local Falcon report import", falcon, local_falcon_connection_path,
          scope_ready: true, operator_ready: true, attempt: falcon&.last_attempt_at, interval: 23.hours),
        *campaign_rows(falcon)
      ]
    end

    private

    def competing_pages_row(connection, import)
      success = connection&.page_week_synced_at
      attempt = connection&.page_week_attempted_at
      row = {key: "competing-pages", name: "Competing pages", group: :analysis,
        frequency: "Weekly, once Search Console has reported a full week",
        last_at: success, last_label: success ? "Weekly search data saved" : "No weekly check recorded",
        next_at: nil, next_label: "Checked after each successful Search Console import.",
        path: competing_pages_path, link_label: "Review competing pages"}
      if attempt && (!success || attempt > success)
        row.merge!(last_at: attempt, last_label: "Latest collection attempt")
      end
      if ["Not connected", "Reconnect", "Setup needed"].include?(import[:status])
        return row.merge(status: import[:status], tone: import[:tone], next_label: import[:next_label])
      end
      country = SearchConsole::DailyPositions.country_for(@site)
      return row.merge(status: "Setup needed", tone: :warning, next_label: "Choose a reporting country in Search Console.") unless country
      return row.merge(status: "No keywords", tone: :idle, next_label: "Add a keyword to start.") unless @site.keywords.exists?
      if connection.page_week_sync_key.present? && attempt && attempt > @now - SearchConsole::CompetingPageSync::LEASE
        return row.merge(status: "Collecting", tone: :active, next_label: "This check is running.")
      end
      if connection.page_week_error.present? || connection.page_week_sync_key.present?
        return row.merge(status: "Retry pending", tone: :warning, detail: success ? "Last successful collection on #{local_stamp(success)}." : nil)
      end
      unless connection.status == "connected" && connection.data_through
        return row.merge(status: "Waiting for Search Console", tone: :idle)
      end
      sync = SearchConsole::CompetingPageSync
      last_week = sync.latest_week(connection.data_through, now: @now)
      partial = SearchConsolePageWeek.where(site: @site, property: connection.property, country: country, partial: true,
        query: sync.tracked_keywords(@site).select("LOWER(phrase)"),
        week_start: (last_week - 7 * (sync::WEEKS - 1))..last_week).exists?
      return row.merge(status: "Some data incomplete", tone: :warning, detail: "Incomplete checks are retried after 24 hours.") if partial

      row.merge(status: success ? "Enabled" : "Awaiting first check", tone: success ? :good : :idle)
    end

    def import_row(key, name, connection, path, scope_ready:, operator_ready:, attempt:, interval: 24.hours)
      success = connection&.synced_at
      row = { key: key, name: name, group: :collection, frequency: "Every #{interval.in_hours.to_i} hours · checked every 15 minutes",
        path: path, link_label: "Connection details", last_at: success,
        last_label: success ? "Last successful sync" : "No successful sync recorded", next_at: nil }
      if attempt && (!success || attempt > success) && (connection.sync_key.present? || %w[delayed reconnect].include?(connection.status))
        row.merge!(last_at: attempt, last_label: "Latest attempt",
          detail: success ? "Last successful sync on #{local_stamp(success)}." : "No successful sync recorded.")
      end
      unless connection
        return row.merge(status: "Not connected", tone: :idle, next_label: "Connect this service to start.")
      end
      if connection.status == "reconnect"
        return row.merge(status: "Reconnect", tone: :warning, next_label: "Waiting for a new connection.")
      end
      if connection.status == "choose_property" || (!scope_ready && connection.status.in?(%w[connected delayed]))
        return row.merge(status: "Setup needed", tone: :warning, next_label: "Select a matching Google property.")
      end
      unless connection.status.in?(%w[connected delayed]) && connection.refresh_token_before_type_cast.present?
        return row.merge(status: "Not connected", tone: :idle, next_label: "Finish connecting this service.")
      end
      unless operator_ready
        return row.merge(status: "Setup needed", tone: :warning, next_label: "Google sign-in needs configuring on the server.")
      end

      due_at = [success && success + interval, attempt && attempt + 1.hour].compact.max
      if connection.sync_key.present? && attempt
        lease = key == "local-falcon" ? 15.minutes : 10.minutes
        return row.merge(status: "Sync started", tone: :active, next_label: "After the current attempt.") if attempt > @now - lease
        return row.merge(status: "Awaiting recovery", tone: :warning, next_at: due_at > @now ? due_at : nil,
          next_label: due_at > @now ? "Next eligible retry" : "Due at the next scheduler check.")
      end
      waiting = !due_at || due_at <= @now
      next_label = waiting ? "Due at the next scheduler check." : "Next eligible sync"
      status, tone = connection.status == "delayed" ? ["Retry pending", :warning] : ["Enabled", :good]
      row.merge(status: status, tone: tone, next_at: waiting ? nil : due_at, next_label: next_label)
    end

    def campaign_rows(connection)
      base = { key: "falcon-campaigns", name: "Local Falcon campaigns", group: :external, status: "Unconfirmed", tone: :idle,
        frequency: "Set in Local Falcon", last_at: nil, last_label: "No run confirmed", next_at: nil,
        next_label: "Awaiting provider schedule.", path: local_falcon_connection_path, link_label: "View Local Falcon" }
      unless connection&.status.in?(%w[connected delayed]) && connection.synced_at && connection.place_id.present?
        return [base.merge(detail: "Connect and sync Local Falcon to see its campaign schedule.")]
      end
      count = connection.result["campaigns"]
      return [base] unless count.is_a?(Integer) && count >= 0
      captured = "Provider schedule last synced on #{local_stamp(connection.synced_at)}."
      return [base.merge(status: "None reported", next_label: "No campaign in the last sync.", detail: captured)] if count.zero?

      snapshots = @site.source_snapshots.where(provider: "Local Falcon", source_path: nil)
        .where("metrics->>'place_id' = ? AND metrics->>'locations' = '1'", connection.place_id)
        .where("external_id ~ '^campaign-[a-f0-9]{15}-[0-9]{4}-[0-9]{2}-[0-9]{2}$'")
      if connection.result.key?("campaign_snapshot_ids")
        ids = connection.result["campaign_snapshot_ids"]
        return [base.merge(detail: captured)] unless ids.is_a?(Array) && ids.uniq.size == count
        snapshots = snapshots.where(external_id: ids)
      else
        # Older imports recorded only a count. Admit a set only on the exact sync
        # date, with that count and the same verified place, so removed campaigns
        # and prior-day/manual snapshots cannot reappear as active schedules.
        snapshots = snapshots.where(observed_on: connection.synced_at.in_time_zone(@site.time_zone).to_date)
      end
      saved = snapshots.order(:title, :id).to_a
      return [base.merge(detail: captured)] unless saved.size == count

      saved.map { |snapshot| campaign_row(snapshot, connection, base, captured) }
    end

    def campaign_row(snapshot, connection, base, captured)
      metrics = snapshot.metrics
      last = provider_time(metrics["last_run"])
      last = nil if last && last > connection.synced_at
      upcoming = provider_time(metrics["next_run"])
      status = metrics["status"].to_s.strip
      paused = %w[paused inactive disabled stopped finished completed cancelled canceled archived].include?(status.downcase)
      stale = connection.status == "delayed" || connection.synced_at < @now - 24.hours || (upcoming && upcoming <= @now)
      current = !paused && !stale && upcoming
      label = if stale
        upcoming ? "Last forecast was #{local_stamp(upcoming)}. Awaiting an update." : "Awaiting an updated provider schedule."
      elsif paused
        "No active provider schedule."
      elsif current
        "Scheduled by Local Falcon"
      else
        "No next run reported."
      end
      base.merge(key: snapshot.external_id.split("-").first(2).join("-"), name: snapshot.title.delete_prefix("Maps campaign · "),
        frequency: metrics["frequency"].to_s.strip.presence&.upcase_first || base[:frequency],
        status: stale ? "Needs refresh" : status.presence&.humanize || "Unconfirmed",
        tone: stale ? :warning : (current ? :good : :idle), last_at: last, last_label: last ? "Provider-reported run" : "No run reported",
        next_at: current ? upcoming : nil, next_label: label, detail: captured)
    end

    def provider_time(value)
      return unless value.is_a?(String) && value.match?(/(?:Z|[+-]\d\d:\d\d)\z/i)
      instant = Time.iso8601(value)
      instant if instant > Time.at(0)
    rescue ArgumentError
      nil
    end

    def local_stamp(time)
      time.in_time_zone(@site.time_zone).strftime("%-d %b %Y at %H:%M %Z")
    end
  end
end
