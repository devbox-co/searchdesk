module AiAssistant
  # Rebuild the scope from current records for requests, dispatch and display.
  # The digest binds an answer to a particular saved review and both sharing grants.
  class PageAdviceRequest
    attr_reader :site, :connection, :setting, :finding

    def initialize(finding:, user:)
      @user = user
      return unless finding&.persisted?
      @site = Site.find_by(id: finding.site_id)
      return unless site
      @finding = SiteFinding.competing_pages.current.find_by(id: finding.id, site_id: site.id)
      @connection = AiConnection.find_by(workspace_id: site.workspace_id)
      @setting = AiSetting.find_by(site_id: site.id)
    end

    def digest
      return @digest if defined?(@digest)
      @digest = scope_digest
    end

    def available?
      digest.present? && connection.status == "ready" && connection.monthly_budget_cents.positive? &&
        connection.month_spend_microusd < connection.monthly_budget_cents * 10_000
    end

    def current
      return unless digest
      AiRun.where(site_id: site.id, site_finding_id: finding.id, user_id: @user.id, kind: "page_advice",
        page_advice_digest: digest, erased_at: nil).order(id: :desc).first
    end

    def create_or_reuse!(retry_run_id:)
      existing = current
      return existing if existing && !(existing.page_advice_retryable? && retry_run_id.to_s == existing.id.to_s)

      run = AiRun.new(site:, user: @user, site_finding: finding, page_advice_digest: digest, kind: "page_advice",
        model: OpenaiClient::MODEL, recipe_version: Recipe.version("page_advice"), setting_revision: setting&.revision,
        connection_revision: connection&.revision, request_key: "page_advice/#{SecureRandom.uuid}",
        report_on: Time.current.in_time_zone(site.time_zone).to_date)
      unless available?
        run.errors.add(:base, "Check the AI connection, Google sharing and workspace allowance before requesting advice.")
        raise ActiveRecord::RecordInvalid.new(run)
      end
      run.save!
      run
    end

    private

    def scope_digest
      return unless finding && connection&.configured? && setting&.share_google? && setting.may_ask?(user: @user)
      source = site.search_console_connection
      return unless source && source.refresh_token_before_type_cast.present? && source.property.present? &&
        finding.evidence["property"] == source.property && finding.evidence["country"].present? &&
        finding.evidence["country"] == SearchConsole::DailyPositions.country_for(site)
      grant = EvidenceAccess.new(site, setting).grant("gsc")
      return unless grant
      enrolled = SearchConsole::CompetingPageSync.tracked_keywords(site).select(:id)
      keyword = site.keywords.where(id: enrolled).find_by(id: finding.keyword_id)
      return unless keyword && keyword.phrase.downcase == finding.evidence["query"]
      Digest::SHA256.hexdigest([site.host, finding.id, keyword.id, CompetingPages::Advice.digest(finding), grant,
        Recipe.version("page_advice"), OpenaiClient::MODEL, connection.revision, setting.revision].to_json)
    end
  end
end
