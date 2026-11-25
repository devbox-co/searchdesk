class AiRun < ApplicationRecord
  QUESTION_LIMIT = 1200
  belongs_to :site
  belongs_to :user, optional: true
  belongs_to :parent, class_name: "AiRun", optional: true
  self.filter_attributes += %i[question evidence answer]

  validates :kind, inclusion: { in: %w[question brief test] }
  validates :question, presence: true, length: { maximum: QUESTION_LIMIT }, if: -> { kind == "question" && !erased_at }
  validates :request_key, :report_on, presence: true
  validate :question_has_no_secret

  def self.published_briefs_for(site:, user:, limit: 12)
    where(site: site, kind: "brief", status: %w[complete fallback], erased_at: nil)
      .order(report_on: :desc, id: :desc).limit(40).lazy.select { |run| run.visible_to?(user: user) }.first(limit)
  end

  def self.request_current_brief!(site:)
    request!(site: site, user: nil, kind: "brief", refresh_recipe: true)
  end

  def self.request!(site:, user:, kind:, question: nil, parent: nil, report_on: nil, request_key: nil, refresh_recipe: false)
    report_on ||= Time.current.in_time_zone(site.time_zone).to_date
    site.with_lock do
      identifier = if kind == "brief"
        brief_request_key(site:, report_on:, refresh_recipe:)
      else
        "#{kind}/#{user&.id}/#{request_key || SecureRandom.uuid}"
      end
      connection = AiConnection.find_by(workspace_id: site.workspace_id)
      setting = AiSetting.find_by(site: site)
      run = find_or_initialize_by(site: site, request_key: identifier)
      if run.new_record?
        run.assign_attributes(user: user, kind: kind, parent: parent, question: question, report_on: report_on,
          connection_revision: connection&.revision, setting_revision: setting&.revision,
          recipe_version: AiAssistant::Recipe.version(kind), model: AiAssistant::OpenaiClient::MODEL)
      elsif run.kind != kind || run.user_id != user&.id || run.parent_id != parent&.id || run.question != question
        run.errors.add(:base, "This request identifier has already been used.")
        raise ActiveRecord::RecordInvalid.new(run)
      end
      unless run.authorized_for_dispatch?(connection: connection, setting: setting)
        run.errors.add(:base, "The current OpenAI connection or site permissions do not allow this request.")
        raise ActiveRecord::RecordInvalid.new(run)
      end
      run.save! if run.new_record?
      run
    end
  end

  def self.brief_request_key(site:, report_on:, refresh_recipe:)
    daily_key = "brief/#{report_on.iso8601}"
    return daily_key unless refresh_recipe

    version = AiAssistant::Recipe.version("brief")
    reports = where(site:, kind: "brief", report_on:)
    reports.where(recipe_version: version).pick(:request_key) || (reports.exists? ? "#{daily_key}/#{version}" : daily_key)
  end
  private_class_method :brief_request_key

  def connection
    AiConnection.find_by(workspace_id: site.workspace_id)
  end

  def authorized_for_dispatch?(connection:, setting:)
    return false if erased_at
    return false unless connection&.configured? && connection.workspace_id == site.workspace_id &&
      connection.revision == connection_revision
    if kind == "test"
      return user_id.present? && site.workspace.memberships.exists?(user_id: user_id, role: "owner")
    end

    return false unless connection.status == "ready" && setting&.enabled? && setting.site_id == site_id &&
      setting.revision == setting_revision
    return setting.daily_brief_enabled? if kind == "brief"
    return false unless kind == "question" && setting.may_ask?(user: user)
    return true unless parent_id
    parent && parent.site_id == site_id && %w[question brief].include?(parent.kind) &&
      %w[complete fallback].include?(parent.status) && parent.visible_to?(user: user)
  end

  def visible_to?(user:)
    return false unless user && !erased_at
    role = Membership.where(user_id: user.id, workspace_id: site.workspace_id).pick(:role)
    return false unless role
    return role == "owner" && user_id == user.id if kind == "test"

    setting = AiSetting.find_by(site: site)
    return false unless setting&.enabled?
    if kind == "question"
      return false unless user_id == user.id && (role == "owner" || (role == "manager" && setting.managers_enabled?))
    elsif kind != "brief" || (role != "owner" && !%w[complete fallback].include?(status))
      return false
    end
    current = self
    while current
      return false if current.site_id != site_id || current.erased_at || (current.kind == "question" && current.user_id != user.id)
      return false if current.evidence.present? && !AiAssistant::Evidence.visible?(site: site, setting: setting, evidence: current.evidence)
      current = current.parent
    end
    true
  end

  def erase_content!
    site.with_lock do
      ids = [id]
      while ids.any?
        rows = AiRun.where(site_id: site_id, id: ids, erased_at: nil)
        self.class.erase_rows!(rows)
        ids = AiRun.where(site_id: site_id, parent_id: ids, erased_at: nil).pluck(:id)
      end
    end
    reload
  end

  def self.erase_history!(site:)
    site.with_lock { erase_rows!(where(site: site, erased_at: nil)) }
  end

  def self.purge_hidden_for!(site:, setting:)
    where(site: site, erased_at: nil, kind: %w[brief question]).where.not(evidence: {}).find_each do |run|
      run.erase_content! unless setting.enabled? && AiAssistant::Evidence.visible?(site: site, setting: setting, evidence: run.evidence)
    end
  end

  def self.erase_rows!(scope)
    now = Time.current
    # Erased rows retain billing receipts, including reservations for interrupted requests.
    # A single UPDATE serialises with the worker's row lock and cannot restore erased content.
    scope.update_all(["question = NULL, answer = '{}'::jsonb, evidence = '{}'::jsonb, erased_at = ?, updated_at = ?, " \
      "finished_at = COALESCE(finished_at, ?), status = CASE WHEN status IN ('pending','running') THEN 'cancelled' ELSE status END", now, now, now])
  end

  private

  def question_has_no_secret
    if question.to_s.match?(/\b(?:sk-(?:proj-|admin-)?[\w-]{8,}|bearer\s+\S+|[\w.+-]+@[\w.-]+\.[a-z]{2,})\b/i)
      errors.add(:question, "must contain only information you want to share about the business")
    end
  end
end
