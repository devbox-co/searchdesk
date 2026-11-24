class LocalFalconSyncJob < ApplicationJob
  queue_as :default

  def perform(id = nil, scheduled: false)
    unless id
      SourceSnapshot.linked_gbp_cache.where(updated_at: ..29.days.ago).delete_all
      LocalFalconConnection.where("state_expires_at < ?", Time.current)
        .update_all(state_digest: nil, state_expires_at: nil, verifier: nil, initiator_id: nil)
      LocalFalconConnection.due.find_each { |row| self.class.perform_later(row.id, scheduled: true) }
      return
    end
    connection = LocalFalconConnection.find_by(id: id)
    return unless connection
    claim = SecureRandom.hex(20)
    client = LocalFalcon::Client.new
    token = connection.with_lock do
      next if connection.refresh_token.blank? || connection.status == "reconnect"
      next if connection.sync_key.present? && connection.last_attempt_at && connection.last_attempt_at > 15.minutes.ago
      next if scheduled && !LocalFalconConnection.due.exists?(id)
      connection.update!(sync_key: claim, last_attempt_at: Time.current)
      connection.access_token
    end
    return unless token
    # Persist a rotated, single-use refresh token before running any report reads.
    token = connection.with_lock do
      next unless connection.sync_key == claim
      if connection.token_expires_at.blank? || connection.token_expires_at <= 2.minutes.from_now
        grant = client.token(connection.client_id, grant_type: "refresh_token", refresh_token: connection.refresh_token)
        connection.update!(access_token: grant.fetch("access_token"), refresh_token: grant["refresh_token"].presence || connection.refresh_token,
          token_expires_at: grant.fetch("expires_in").to_i.seconds.from_now)
      end
      connection.access_token
    end
    return unless token
    report = LocalFalcon::ReportReader.new(client.open_session(token), connection.site, connection.place_id).read
    connection.site.with_lock do
      current = LocalFalconConnection.lock.find_by(id: id, sync_key: claim)
      next unless current
      if report[:rows].none? { |row| row[:external_id] == SourceSnapshot::GBP_CACHE_ID }
        current.site.source_snapshots.linked_gbp_cache.delete_all
      end
      report[:rows].each do |row|
        snapshot = current.site.source_snapshots.find_or_initialize_by(provider: row[:provider], external_id: row[:external_id])
        # A previous manual import may contain a richer dated source. Leave its provenance intact.
        next if snapshot.persisted? && snapshot.source_path.present?
        snapshot.assign_attributes(row)
        snapshot.save! if snapshot.new_record? || snapshot.changed?
      end
      current.update!(place_id: report[:place_id], verified_name: report[:verified_name], result: report[:result],
        synced_at: Time.current, sync_key: nil, last_error: nil, status: "connected")
    end
  rescue LocalFalcon::Client::Error, ActiveRecord::RecordInvalid => e
    status = e.is_a?(LocalFalcon::Client::AccessError) ? "reconnect" : "delayed"
    msg = e.is_a?(ActiveRecord::RecordInvalid) ? "Local Falcon returned an invalid report. Previous evidence is retained." : e.message
    LocalFalconConnection.where(id: id, sync_key: claim).update_all(status: status, sync_key: nil, last_error: msg, updated_at: Time.current)
  rescue ActiveRecord::RecordNotFound
    # Disconnecting while a read was in flight invalidates its claim.
  end
end
