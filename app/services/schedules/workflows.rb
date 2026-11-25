module Schedules
  # Describe recorded site work. Reading this page never reserves tasks or calls a provider.
  class Workflows
    include Rails.application.routes.url_helpers

    def initialize(site:, now:)
      @site = site
      @now = now.in_time_zone(site.time_zone)
      @series = TrackingSeries.where(keyword_id: site.keywords.select(:id), source: site.tracking_mode)
    end

    def rows
      [rankings, brief, audit]
    end

    private

    def rankings
      slots = DailySlot.where(tracking_series_id: @series.select(:id))
      last_at, last_label = last_rank_event(slots)
      active = @series.current.where(paused: false).to_a
      source = @site.tracking_mode
      row = { key: "rankings", name: "Organic keyword rankings", group: :collection,
        frequency: "Daily from 08:00 in each keyword’s tracking time zone",
        last_at: last_at, last_label: last_label, next_at: nil, next_label: "No automatic collection",
        path: rankings_path(source: "local"), link_label: "View rankings" }
      if source == "manual"
        return row.merge(status: "Manual imports", tone: :idle, frequency: "On import")
      end
      if active.empty?
        return row.merge(status: @series.current.exists? ? "Paused" : "No active keywords", tone: :idle)
      end

      # The site time zone can change after enrollment. The worker follows each
      # series' saved zone to determine its reporting day and its 08:00 slot.
      days = active.to_h { |series| [series.id, series.date_in_zone(@now)] }
      current_slots = slots.where(tracking_series_id: days.keys, day: days.values.uniq)
        .select(:id, :day, :tracking_series_id, :status, :attempted_at, :retry_after, :last_queued_at)
        .select { |slot| days[slot.tracking_series_id] == slot.day }.index_by(&:tracking_series_id)
      provider = Tracking::DataForSeo
      eligible = active
      poll_at = nil
      if source == "dataforseo"
        return row.merge(status: "Provider disabled", tone: :warning) unless provider.enabled?
        # Existing reservations can be collected even when new submissions have
        # reached a cap. The collector also continues to poll prior reporting days.
        poll_at = earliest_provider_poll(slots, active)
        eligible = active.select do |series|
          provider.series_allowed?(series.id) && provider.daily_task_limit.positive? && provider.rolling_task_limit.positive? &&
            series.settings["location_code"].to_i.positive? && series.settings["location_code"] == @site.rank_location_code
        end
        return row.merge(status: "Collection blocked", tone: :warning,
          detail: "Check the authorised ranking series, verified location and provider task limits.") if eligible.empty? && poll_at.nil?
      end
      new_times = eligible.filter_map do |series|
        slot = current_slots[series.id]
        next if source == "dataforseo" && slot&.attempted_at && !AiBriefScheduleJob::TERMINAL_SLOT_STATES.include?(slot.status)
        rank_eligibility(series, days.fetch(series.id), slot)
      end
      new_at = new_times.min
      limit = submission_limit_at(new_at, provider) if source == "dataforseo" && new_at
      next_at = [poll_at, (new_at unless limit)].compact.min
      tally = current_slots.values.map(&:status).tally
      complete = tally.fetch("ranked", 0) + tally.fetch("outside", 0)
      detail = "#{complete} of #{active.size} keyword/device readings complete for the current reporting day"
      detail += ", #{tally['incomplete']} incomplete" if tally["incomplete"]
      detail += ", #{tally['failed']} failed" if tally["failed"]
      detail += ", #{tally['held']} on hold" if tally["held"]
      detail += ". #{eligible.size} authorised for new submissions." if eligible.size < active.size
      detail += ". The #{limit} blocks new submissions for the next collection window." if limit
      return row.merge(status: "Submission limit reached", tone: :warning, detail: detail,
        next_label: "The worker rechecks available capacity") if limit && !poll_at
      return row.merge(status: "On hold", tone: :warning, detail: detail, next_label: "Waiting for a new reporting day") unless next_at
      status, tone = if source == "demo"
        ["Demo data", :good]
      elsif poll_at && (limit || eligible.empty?)
        ["Checking existing requests", :active]
      elsif tally["held"] || eligible.size < active.size
        [tally["held"] == active.size ? "On hold" : "Partly on hold", :warning]
      elsif current_slots.values.any? { |slot| %w[submitted dispatching].include?(slot.status) }
        ["Collecting", :active]
      else
        ["Enabled", :good]
      end
      row.merge(status: status, tone: tone, detail: detail, next_at: next_at > @now ? next_at : nil,
        next_label: next_at <= @now ? "Eligible at the next worker check" : "Earliest scheduled check")
    end

    def earliest_provider_poll(slots, active)
      valid = active.select { |series| series.settings["location_code"].to_i.positive? }.map(&:id)
      slots.where(tracking_series_id: valid, status: %w[pending submitted dispatching held]).where.not(attempted_at: nil)
        .where("status <> 'held' OR attempted_at >= ?", @now - 2.days)
        .pluck(:retry_after, :last_queued_at).map do |retry_at, queued_at|
          [@now, retry_at, queued_at && queued_at + 3.minutes].compact.max
        end.min
    end

    def submission_limit_at(timestamp, provider)
      # Account-wide caps apply across sites. Expose only the limiting rule.
      utc = timestamp.utc
      return "UTC daily task limit" if DailySlot.where(attempted_at: utc.beginning_of_day..).offset(provider.daily_task_limit - 1).exists?
      return "rolling 31-day task limit" if DailySlot.where("attempted_at > ?", utc - 31.days).offset(provider.rolling_task_limit - 1).exists?
      nil
    end

    def last_rank_event(slots)
      results = RankObservation.where(daily_slot_id: slots.select(:id))
      result = results.order(updated_at: :desc, id: :desc).pick(:updated_at, :status)
      events = []
      if result
        kind = {"incomplete" => "Incomplete reading saved", "outside" => "Outside-range reading saved"}
        events << [result.first, kind.fetch(result.last, "Ranking saved")]
      end
      attempt = slots.maximum(:attempted_at)
      events << [attempt, "Provider submission reserved"] if attempt
      outcome = slots.where(status: %w[failed held]).order(updated_at: :desc, id: :desc).pick(:updated_at, :status)
      events << [outcome.first, outcome.last == "held" ? "Collection put on hold" : "Collection failed"] if outcome
      events.max_by(&:first) || [nil, "No recorded run"]
    end

    def rank_eligibility(series, day, slot)
      zone = series.settings.fetch("time_zone")
      if slot && !AiBriefScheduleJob::TERMINAL_SLOT_STATES.include?(slot.status)
        return [@now, slot.retry_after, slot.last_queued_at && slot.last_queued_at + 3.minutes].compact.max
      end
      date = [slot ? day.tomorrow : day, series.enrolled_on].max
      [date.in_time_zone(zone).change(hour: 8), @now].max
    end

    def brief
      runs = AiRun.where(site: @site, kind: "brief")
      latest = runs.where(erased_at: nil).order(report_on: :desc, id: :desc)
        .pick(:status, :finished_at, :attempted_at, :created_at)
      row = { key: "daily_brief", name: "Daily SEO brief", group: :analysis,
        frequency: "Daily from 09:00 · uses available data from noon", next_at: nil,
        last_at: latest && (latest[1] || latest[2] || latest[3]),
        last_label: latest ? brief_run_label(latest.first) : "No recorded brief",
        path: assistant_path, link_label: "View assistant" }
      setting = AiSetting.find_by(site_id: @site.id)
      unless setting&.enabled? && setting.daily_brief_enabled?
        return row.merge(status: "Off", tone: :idle, next_label: "Daily briefs are off")
      end
      # Check credential presence in PostgreSQL without reading the encrypted secret.
      connection = AiConnection.where(workspace_id: @site.workspace_id).where.not(api_key: nil)
        .select(:workspace_id, :monthly_budget_cents, :status).first
      block = brief_block(connection)
      return row.merge(status: block, tone: :warning, next_label: "Paused until the account is ready") if block
      today = @now.to_date
      day = runs.exists?(report_on: today) ? today.tomorrow : today
      start = day.in_time_zone(@site.time_zone).change(hour: 9)
      today_active = day == today && @now >= start
      waiting = today_active && @now.hour < 12 && waiting_for_rankings?(today)
      row.merge(status: waiting ? "Waiting for rankings" : "Enabled", tone: waiting ? :active : :good,
        next_at: today_active ? nil : start,
        next_label: if waiting
          "When rankings settle, or from 12:00 today"
        elsif today_active
          "Eligible at the next worker check"
        else
          "Earliest start, after ranking collection"
        end)
    end

    def brief_block(connection)
      return "OpenAI setup needed" unless AiConnection.owner_controlled_installation? && connection
      return "Reconnect OpenAI" if connection.status == "reconnect"
      return "OpenAI credits exhausted" if connection.status == "credits_exhausted"
      return "Connection test needed" unless connection.status == "ready"
      return "Allowance paused" if connection.monthly_budget_cents.zero?
      return "Allowance reached" if connection.month_spend_microusd(now: @now) >= connection.monthly_budget_cents * 10_000
      nil
    end

    def waiting_for_rankings?(day)
      return false if @site.tracking_mode == "manual"
      settled = DailySlot.where(day: day, status: AiBriefScheduleJob::TERMINAL_SLOT_STATES).select(:tracking_series_id)
      @series.current.where(paused: false, enrolled_on: ..day).where.not(id: settled).exists?
    end

    def brief_run_label(status)
      { "complete" => "Brief published", "fallback" => "Local-evidence brief published", "pending" => "Brief queued",
        "running" => "Brief started", "budget" => "Stopped at the spending limit", "cancelled" => "Brief cancelled",
        "expired" => "Brief expired" }.fetch(status, "Brief failed")
    end

    def audit
      latest = SiteAudit.where(site: @site, host: @site.host).order(created_at: :desc, id: :desc)
        .select(:status, :trigger_kind, :created_at, :started_at, :finished_at).first
      enabled = @site.weekly_site_audit_enabled?
      row = { key: "site_audit", name: "Website crawl", group: :analysis, frequency: "Every 7 days from the latest crawl request",
        last_at: latest && (latest.finished_at || latest.started_at || latest.created_at),
        last_label: latest ? "#{latest.trigger_kind.capitalize} crawl · #{latest.status}" : "No recorded crawl",
        path: site_audit_path, link_label: "View site audit" }
      return row.merge(status: "Off", tone: :idle, next_at: nil, next_label: "Manual crawls available") unless enabled
      due = latest && latest.created_at + 7.days
      working = latest && %w[queued running].include?(latest.status)
      row.merge(status: working ? latest.status.capitalize : "Enabled", tone: working ? :active : :good,
        next_at: due && due > @now ? due : nil, next_label: due && due > @now ? "Next eligible weekly crawl" : (working ? "Current crawl in progress" : "Eligible at the next worker check"))
    end
  end
end
