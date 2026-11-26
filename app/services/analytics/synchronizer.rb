module Analytics
  class Synchronizer
    def self.call(connection, client: Client.new, scheduled: false)
      key = SecureRandom.uuid
      claimed = connection.with_lock do
        next false unless connection.property_id.present? && %w[connected delayed].include?(connection.status)
        next false if scheduled && !AnalyticsConnection.due_for_sync.exists?(connection.id)
        next false if connection.sync_key && connection.sync_started_at && connection.sync_started_at > 10.minutes.ago
        connection.update!(sync_key: key, sync_started_at: Time.current)
      end
      return false unless claimed

      grant = connection.grant_key
      host = connection.site.host
      token = connection.token_for!(client, expected_grant: grant)
      binding = client.binding(token: token, property: connection.property_id, host: host)
      # Three property-local calendar days allow standard daily processing to settle.
      last_day = Time.current.in_time_zone(binding.fetch(:property_zone)).to_date - 3
      report = {
        "current" => client.period(token: token, binding: binding, from: last_day - 27, through: last_day),
        "previous" => client.period(token: token, binding: binding, from: last_day - 55, through: last_day - 28)
      }
      host_id = Digest::SHA256.hexdigest(host).first(24)
      connection.with_lock do
        return false unless connection.sync_key == key && connection.grant_key == grant && connection.site.reload.host == host
        report.each_value do |period|
          snapshot = connection.site.source_snapshots.find_or_initialize_by(provider: "Google Analytics 4", external_id: "ga4-google-organic-v1-#{binding[:property_id]}-#{host_id}-#{period.fetch('end')}")
          snapshot.update!(observed_on: period.fetch("end"), title: "Google organic sessions · 28 days to #{period.fetch('end')}",
            source_url: "https://analytics.google.com/analytics/web/#/p#{binding[:property_id]}/reports/reportinghub",
            scope: "GA4 property #{binding[:property_id]} · #{host} and its www alias · verified web streams · session source google / medium organic · #{binding[:property_zone]}. Key events have not been validated as enquiries.",
            metrics: period.merge("property_id" => binding[:property_id], "stream_ids" => binding[:stream_ids], "reporting_time_zone" => binding[:property_zone]))
        end
        connection.update!(binding.merge(report: report, status: "connected", synced_at: Time.current, last_error: nil, sync_key: nil))
      end
      true
    rescue Client::Error, KeyError, TypeError, ArgumentError => e
      status = e.is_a?(Client::AccessError) ? "reconnect" : "delayed"
      message = e.is_a?(Client::Error) ? e.message : "Google returned an incomplete report. The last successful report was kept."
      AnalyticsConnection.where(id: connection.id, sync_key: key).update_all(status: status, last_error: message, sync_key: nil)
      false
    rescue ActiveRecord::RecordNotFound
      false
    end
  end
end
