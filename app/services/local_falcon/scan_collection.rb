require "digest"

module LocalFalcon
  class ScanCollection
    class Unavailable < StandardError; end

    PROVIDER = "Local Falcon scan requests"
    SIZES = [3, 5, 7].freeze
    MAX_POLLS = 5

    def self.scope(site)
      site.source_snapshots.where(provider: PROVIDER).where("metrics->>'host' = ?", site.host)
    end

    def self.status_text(receipt)
      case receipt.metrics["status"]
      when "queued" then "Queued for the worker"
      when "pending" then "Processing at Local Falcon"
      when "submitting", "polling"
        receipt.updated_at > 5.minutes.ago ? "Checking with Local Falcon" : "Provider response unconfirmed"
      when "captured" then "Grid saved"
      when "cancelled" then "Request cancelled"
      else "Provider response unconfirmed"
      end
    end

    def self.verified?(connection)
      connection && connection.refresh_token.present? && connection.access_token.present? &&
        %w[connected delayed].include?(connection.status) && connection.synced_at &&
        connection.place_id.present? && connection.verified_name.present?
    end

    def self.revision(site)
      connection = site.local_falcon_connection
      return unless verified?(connection)

      Digest::SHA256.hexdigest([site.host, connection.id, connection.ai_grant_revision, connection.place_id].to_json)
    end

    def self.request(site:, owner_id:, keyword_id:, size:, radius:, revision:)
      size = Integer(size.to_s, 10, exception: false)
      radius = Float(radius.to_s, exception: false) if radius.to_s.match?(/\A\d{1,3}(?:\.\d{1,2})?\z/)
      unless SIZES.include?(size) && radius.is_a?(Float) && radius.between?(0.1, 100)
        raise Unavailable, "Choose a supported grid size and a radius between 0.1 and 100 miles."
      end

      receipt = site.with_lock do
        approved = self.revision(site)
        owner = site.workspace.memberships.exists?(user_id: owner_id, role: "owner")
        unless approved && approved == revision && owner
          raise Unavailable, "Verify the current Local Falcon location and review the scan settings again."
        end
        keyword = site.keywords.find_by(id: keyword_id)
        unless keyword && keyword.phrase.length.between?(1, 200)
          raise Unavailable, "Choose a tracked keyword on this site."
        end
        day = Time.current.in_time_zone(site.time_zone).to_date
        identity = "google-maps-#{day}"
        existing = scope(site).find_by(external_id: identity)
        return existing if existing

        scope(site).create!(external_id: identity, observed_on: day, title: "#{keyword.phrase} · Maps scan request",
          keyword: keyword.phrase, scope: "One owner-approved Google Maps scan using existing Local Falcon credits.",
          metrics: { "host" => site.host, "revision" => approved, "keyword_id" => keyword.id,
            "place_id" => site.local_falcon_connection.place_id, "size" => size, "radius" => radius,
            "credits" => size**2, "status" => "queued", "polls" => 0 })
      end
      unless LocalFalconScanJob.perform_later(receipt.id, owner_id)
        raise ActiveJob::EnqueueError
      end
      receipt
    rescue ActiveJob::EnqueueError, SolidQueue::Job::EnqueueError
      mark_unconfirmed(receipt)
      raise Unavailable, "The scan could not be queued. Its reservation was kept."
    end

    def self.perform(receipt, owner_id)
      site = receipt.site
      stage = receipt.with_lock do
        metrics = receipt.metrics
        state = metrics["status"]
        next unless receipt.provider == PROVIDER && %w[queued pending].include?(state)

        unless revision(site) == metrics["revision"] && metrics["host"] == site.host &&
            site.workspace.memberships.exists?(user_id: owner_id, role: "owner") &&
            site.keywords.exists?(id: metrics["keyword_id"], phrase: receipt.keyword)
          receipt.update!(metrics: metrics.merge("status" => "cancelled"))
          next
        end
        if state == "queued" && receipt.created_at < 30.minutes.ago
          receipt.update!(metrics: metrics.merge("status" => "cancelled"))
          next
        end
        receipt.update!(metrics: metrics.merge("status" => state == "queued" ? "submitting" : "polling"))
        state
      end
      return unless stage

      metrics = receipt.metrics
      client = client_for(site, metrics.fetch("revision"))
      reader = ReportReader.new(client, site, metrics.fetch("place_id"))
      if stage == "queued"
        location = reader.verified_google_location
        center = [Float(location["lat"], exception: false), Float(location["lng"], exception: false)]
        unless center.first&.between?(-90, 90) && center.last&.between?(-180, 180)
          raise Unavailable, "The verified listing has no usable map centre."
        end
        site.with_lock do
          unless revision(site) == metrics["revision"] && site.workspace.memberships.exists?(user_id: owner_id, role: "owner") &&
              site.keywords.exists?(id: metrics["keyword_id"], phrase: receipt.keyword)
            raise Unavailable, "The approved scan settings changed."
          end
          key = client.submit_google_scan(place: metrics.fetch("place_id"), keyword: receipt.keyword,
            size: metrics.fetch("size"), radius: metrics.fetch("radius"), center: center)
          receipt.update!(metrics: metrics.merge("report_key" => key, "center" => center, "status" => "pending"))
        end
        return queue_poll(receipt, owner_id)
      end

      fields = { keyword: receipt.keyword, grid_size: metrics.fetch("size"), radius: metrics.fetch("radius"), distance_unit: "mi" }
      captured = reader.completed_grid(metrics.fetch("report_key"), expected: fields, center: metrics.fetch("center"))
      if captured
        site.with_lock do
          if revision(site) == metrics["revision"] && site.host == metrics["host"] &&
              site.workspace.memberships.exists?(user_id: owner_id, role: "owner")
            snapshot = store_grid(site, captured)
            receipt.update!(metrics: metrics.merge("status" => "captured", "snapshot_id" => snapshot.id))
          else
            receipt.update!(metrics: metrics.merge("status" => "cancelled"))
          end
        end
      else
        poll_again(receipt, owner_id)
      end
    rescue Client::ToolError
      if stage == "pending"
        poll_again(receipt, owner_id)
      else
        mark_unconfirmed(receipt)
      end
    rescue Unavailable, Client::Error
      mark_unconfirmed(receipt)
    end

    # Reconcile a known provider report without submitting a new paid scan.
    def self.import!(site:, key:, expected: {}, center: nil)
      raise Unavailable, "Enter a valid Local Falcon report key." unless ReportReader::REPORT_KEY.match?(key.to_s)

      approved = revision(site)
      raise Unavailable, "Verify the Local Falcon connection before importing a grid." unless approved
      client = client_for(site, approved)
      reader = ReportReader.new(client, site, site.local_falcon_connection.place_id)
      reader.verified_google_location
      captured = reader.completed_grid(key, expected: expected, center: center)
      raise Unavailable, "The matching grid is still processing or has unavailable pins." unless captured

      site.with_lock do
        raise Unavailable, "The Local Falcon connection changed." unless revision(site) == approved
        snapshot = store_grid(site, captured)
        receipt = scope(site).where("metrics->>'report_key' = ? AND metrics->>'revision' = ?", key, approved).first
        if receipt && receipt.keyword == snapshot.keyword &&
            receipt.metrics.values_at("place_id", "size", "radius") == snapshot.metrics.values_at("place_id", "grid_size", "radius")
          receipt.with_lock do
            receipt.update!(metrics: receipt.metrics.merge("status" => "captured", "snapshot_id" => snapshot.id))
          end
        end
        snapshot
      end
    end

    def self.client_for(site, expected)
      client = Client.new
      connection = site.local_falcon_connection
      raise Unavailable, "Local Falcon access is unavailable." unless connection

      token = connection.with_lock do
        unless revision(site) == expected
          raise Unavailable, "Local Falcon access changed."
        end
        if connection.token_expires_at.blank? || connection.token_expires_at <= 2.minutes.from_now
          grant = client.token(connection.client_id, grant_type: "refresh_token", refresh_token: connection.refresh_token)
          connection.update!(access_token: grant.fetch("access_token"), refresh_token: grant["refresh_token"].presence || connection.refresh_token,
            token_expires_at: grant.fetch("expires_in").to_i.seconds.from_now)
        end
        connection.access_token
      end
      client.open_session(token)
    end

    def self.store_grid(site, captured)
      row, grid = captured
      snapshot = site.source_snapshots.find_or_initialize_by(provider: row.fetch(:provider), external_id: row.fetch(:external_id))
      snapshot.assign_attributes(row) unless snapshot.persisted? && snapshot.source_path.present?
      raise Unavailable, "The saved source does not match the verified Maps grid." unless ScanGrid.bound?(grid, snapshot)
      snapshot.update!(map_grid: grid)
      snapshot
    end

    def self.poll_again(receipt, owner_id)
      pending = receipt.with_lock do
        next unless receipt.metrics["status"] == "polling"

        count = receipt.metrics.fetch("polls") + 1
        receipt.update!(metrics: receipt.metrics.merge("polls" => count, "status" => count < MAX_POLLS ? "pending" : "unconfirmed"))
        count < MAX_POLLS
      end
      queue_poll(receipt, owner_id) if pending
    end

    def self.mark_unconfirmed(receipt)
      receipt.with_lock do
        next if receipt.metrics["status"] == "captured"
        receipt.update!(metrics: receipt.metrics.merge("status" => "unconfirmed"))
      end
    end

    def self.queue_poll(receipt, owner_id)
      unless LocalFalconScanJob.set(wait: 45.seconds).perform_later(receipt.id, owner_id)
        raise ActiveJob::EnqueueError
      end
    rescue ActiveJob::EnqueueError, SolidQueue::Job::EnqueueError
      mark_unconfirmed(receipt)
    end

    private_class_method :client_for, :store_grid, :poll_again, :queue_poll, :mark_unconfirmed
  end
end
