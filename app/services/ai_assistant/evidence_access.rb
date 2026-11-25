module AiAssistant
  # Local-only provenance. The provider receives the selected facts, never these
  # identifiers. Display and dispatch run the same check against current records.
  class EvidenceAccess
    RECORD_TYPES = %w[keywords observations actions tasks snapshots search_reports].freeze
    FLAGS = {"google" => :share_google, "maps" => :share_maps, "semrush" => :share_semrush}.freeze
    attr_reader :metadata

    def initialize(site, setting)
      @site, @setting = site, setting
      @metadata = {"host" => site.host, "sources" => [], "grants" => {}, "records" => {}, "profile" => {}}
    end

    def record(sources: [], grants: {}, expires_at: nil, profile: nil, **records)
      @metadata["profile"][profile.to_s] = profile_digest(profile) if profile
      @metadata["sources"] |= sources
      @metadata["grants"].merge!(grants)
      if expires_at
        deadline = expires_at.utc.iso8601(6)
        @metadata["expires_at"] = [@metadata["expires_at"], deadline].compact.min
      end
      records.each do |kind, ids|
        key = kind.to_s
        raise ArgumentError, "Unrecognised evidence reference" unless RECORD_TYPES.include?(key)
        @metadata["records"][key] = Array(@metadata["records"][key]) | ids
      end
    end

    def self.visible?(site:, setting:, evidence:)
      return false unless site.persisted? && setting&.site_id == site.id && evidence.is_a?(Hash) &&
        evidence["schema"] == Evidence::SCHEMA && evidence["site_id"] == site.id
      current = Site.find_by(id: site.id)
      current_setting = setting.persisted? ? AiSetting.find_by(site_id: site.id, id: setting.id) : setting
      return false unless current && current_setting
      new(current, current_setting).admitted?(evidence["access"])
    end

    def admitted?(access)
      return false unless access.is_a?(Hash) && access["sources"].is_a?(Array) &&
        access["grants"].is_a?(Hash) && access["records"].is_a?(Hash) &&
        access["host"] == @site.host && access["profile"].is_a?(Hash)
      return false if access["expires_at"] && Time.iso8601(access.fetch("expires_at")) <= Time.current
      return false unless access["sources"].all? { |k| FLAGS.key?(k) && @setting.public_send(FLAGS.fetch(k)) }
      return false unless access["grants"].all? { |k, id| id.present? && grant(k) == id }
      return false unless access["profile"].all? { |field, id| AiSetting::PROFILE.include?(field) && profile_digest(field) == id }
      access["records"].all? do |kind, ids|
        RECORD_TYPES.include?(kind) && ids.is_a?(Array) && (ids.empty? || relation(kind).where(id: ids).count == ids.uniq.size)
      end
    rescue ArgumentError, TypeError
      false
    end

    def grant(source)
      case source
      when "gsc"
        c = @site.search_console_connection
        parts = [c.id, c.ai_grant_revision, c.property] if active?(c) && c.property.present? && SearchConsole::Client.matches?(c.property, @site.host)
      when "ga4"
        c = @site.analytics_connection
        parts = [c.id, c.grant_key, c.property_id, c.verified_host, Array(c.stream_ids).sort] if active?(c) && c.property_id.present? &&
          c.grant_key.present? && Tracking::ResultUrl.host_matches?(@site.host, c.verified_host)
      when "falcon"
        c = @site.local_falcon_connection
        parts = [c.id, c.ai_grant_revision, c.place_id] if active?(c) && c.place_id.present? && c.verified_name.present?
      end
      Digest::SHA256.hexdigest(parts.to_json) if parts && parts.all?(&:present?)
    end

    private

    def profile_digest(field)
      Digest::SHA256.hexdigest(@setting[field].to_s)
    end

    def active?(connection)
      connection && %w[connected delayed].include?(connection.status)
    end

    def relation(kind)
      case kind
      when "keywords" then @site.keywords
      when "observations" then RankObservation.joins(daily_slot: {tracking_series: :keyword}).where(keywords: {site_id: @site.id})
      when "actions" then KeywordAction.for_site(@site)
      when "tasks" then @site.project_tasks
      when "snapshots" then SourceSnapshot.visible_for(@site)
      when "search_reports" then SearchConsoleReport.joins(:search_console_connection).where(search_console_connections: {site_id: @site.id})
      end
    end
  end
end
