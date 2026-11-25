module SearchConsole
  class Synchronizer
    def self.call(connection, client: Client.new, scheduled: false)
      key = SecureRandom.uuid
      started = connection.with_lock do
        next false if scheduled && !SearchConsoleConnection.due_for_sync.exists?(connection.id)
        next false unless connection.property.present? && connection.refresh_token.present? && connection.status != "reconnect"
        next false if connection.sync_key && connection.sync_started_at && connection.sync_started_at > 10.minutes.ago
        connection.update!(sync_key: key, sync_started_at: Time.current)
        true
      end
      return false unless started
      property = connection.property
      raise Client::AccessError, "The selected property no longer matches the site" unless Client.matches?(property, connection.site.host)
      token = connection.access_token
      if token.blank? || connection.token_expires_at.blank? || connection.token_expires_at < 2.minutes.from_now
        refreshed = client.refresh(connection.refresh_token)
        token = refreshed.fetch("access_token")
        connection.with_lock do
          return false unless connection.sync_key == key
          connection.update!(access_token: token, token_expires_at: Time.current + refreshed.fetch("expires_in").to_i.seconds)
        end
      end
      builder = ReportBuilder.new(client: client, token: token, property: property, site: connection.site)
      report = builder.call
      report["sitemaps"] = SitemapSummary.fetch(client: client, token: token, property: property)
      connection.with_lock do
        return false unless connection.sync_key == key && connection.property == property
        if builder.position_country != DailyPositions.country_for(connection.site.reload)
          connection.update!(sync_key: nil)
          return false
        end
        DailyPositions.persist!(site: connection.site, property: property, country: builder.position_country,
          terms: builder.position_terms.map(&:downcase).uniq, start_day: builder.position_start,
          end_day: builder.position_end, rows: builder.position_rows)
        history = connection.search_console_reports.find_or_initialize_by(property: property, period_end: report.dig("current", "end"))
        history.update!(report: report)
        connection.search_console_reports.where("period_end < ?", 13.months.ago.to_date).delete_all
        connection.update!(report: report, synced_at: Time.current, data_through: report["last_reported_day"], status: "connected",
                           sync_key: nil, last_error: nil)
      end
      true
    rescue Client::Error, KeyError, TypeError, ArgumentError, ActiveRecord::RecordInvalid => e
      status = e.is_a?(Client::AccessError) ? "reconnect" : "delayed"
      message = e.is_a?(Client::Error) ? e.message : "Google returned an incomplete report. The last successful report was kept."
      connection.class.where(id: connection.id, sync_key: key).update_all(status: status, last_error: message, sync_key: nil)
      false
    rescue ActiveRecord::RecordNotFound
      false
    end
  end
end
