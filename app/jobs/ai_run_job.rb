class AiRunJob < ApplicationJob
  MAX_PENDING_AGE = 24.hours

  def perform(run_id)
    run = AiRun.find_by(id: run_id)
    return unless run&.status == "pending"
    connection = run.connection
    unless connection
      AiRun.where(id: run.id, status: "pending").update_all(status: "cancelled",
        actual_microusd: 0, finished_at: Time.current, failure_code: "consent_changed", updated_at: Time.current)
      return
    end

    payload = reserve(connection, run)
    dispatch(connection, run, payload) if payload
  rescue ActiveRecord::RecordNotFound
    # The workspace, site, connection or run was removed during delivery.
    nil
  end

  private

  def provider
    AiAssistant::OpenaiClient.new
  end

  def with_controls(connection, run)
    connection.with_lock do
      setting = AiSetting.lock.find_by(site_id: run.site_id)
      run.lock!
      yield(setting)
    end
  end

  def current?(run, connection, setting)
    run.authorized_for_dispatch?(connection: connection, setting: setting) &&
      run.model == AiAssistant::OpenaiClient::MODEL && run.recipe_version == AiAssistant::Recipe.version(run.kind)
  end

  def expired?(run)
    run.created_at < MAX_PENDING_AGE.ago ||
      (run.kind == "brief" && run.report_on != Time.current.in_time_zone(run.site.time_zone).to_date)
  end

  def stop_before_send(run, status, code)
    run.update!(status: status, failure_code: code, actual_microusd: 0, finished_at: Time.current)
    nil
  end

  def reserve(connection, run)
    with_controls(connection, run) do |setting|
      next unless run.status == "pending"
      next stop_before_send(run, "cancelled", "consent_changed") unless current?(run, connection, setting)
      next stop_before_send(run, "expired", "stale") if expired?(run)
      parent = allowed_parent(run, setting)
      evidence = if run.kind == "test"
        AiAssistant::Recipe.synthetic_evidence
      else
        AiAssistant::Evidence.build(site: run.site, setting: setting, day: run.report_on,
          kind: run.kind, question: run.question, parent: parent)
      end
      if run.kind == "question" && evidence.fetch("facts").empty? && AiAssistant::Playbooks.for_question(run.question)
        answer = AiAssistant::Recipe.render({ "findings" => [] }, [], kind: "question")
        run.update!(status: "complete", evidence:, answer:, actual_microusd: 0, finished_at: Time.current)
        next
      end
      payload = AiAssistant::OpenaiClient.prepare(kind: run.kind, evidence: evidence,
        question: run.kind == "question" ? run.question : nil, previous: prior_context(parent))
      if connection.month_spend_microusd + payload.reservation_microusd > connection.monthly_budget_cents * 10_000
        next stop_before_send(run, "budget", "monthly_limit")
      end
      evidence["receipt"] = {
        "tariff" => AiAssistant::OpenaiClient::TARIFF_VERSION,
        "prepared_fact_ids" => payload.facts.pluck("id"),
        "facts_sha256" => Digest::SHA256.hexdigest(JSON.generate(payload.facts))
      }
      unless run.kind == "test"
        evidence["receipt"]["playbooks"] = { "version" => AiAssistant::Playbooks::VERSION, "keys" => payload.playbook_keys }
      end
      run.update!(status: "running", attempted_at: Time.current, reserved_microusd: payload.reservation_microusd, evidence: evidence)
      payload
    rescue AiAssistant::OpenaiClient::Error => e
      stop_before_send(run, "failed", e.code)
    end
  end

  def allowed_parent(run, setting)
    return unless run.kind == "question" && run.parent_id
    parent = AiRun.find_by(id: run.parent_id, site_id: run.site_id, kind: %w[question brief],
      status: %w[complete fallback], erased_at: nil)
    parent if parent && (parent.kind == "brief" || parent.user_id == run.user_id) &&
      parent.setting_revision == setting.revision &&
      AiAssistant::Evidence.visible?(site: run.site, setting: setting, evidence: parent.evidence)
  end

  def prior_context(parent)
    return unless parent
    ids = parent.answer.fetch("findings", []).flat_map { |row| row.fetch("fact_ids", []) }
    prior = parent.evidence.fetch("facts", []).select { |f| ids.include?(f["id"]) }.first(3)
    { kind: parent.kind, report_date: parent.report_on.iso8601, question: parent.question&.first(1200),
      cited_facts: prior.map { |f| f.fetch("text").first(500) } }.compact
  end

  def dispatch(connection, run, payload)
    with_controls(connection, run) do |setting|
      if run.status == "cancelled" && run.erased_at && run.actual_microusd.nil?
        # Only the process that reserved this payload enters dispatch. A concurrent
        # history deletion won the lock before that process sent any provider request.
        run.update!(actual_microusd: 0)
      end
      next unless run.status == "running" && run.erased_at.nil?
      permitted = current?(run, connection, setting) && (run.kind == "test" ||
        AiAssistant::Evidence.visible?(site: run.site, setting: setting, evidence: run.evidence))
      # Earlier context travels in this request too. Its source may have been withdrawn since reservation.
      permitted &&= allowed_parent(run, setting).present? if run.parent_id
      next stop_before_send(run, "cancelled", "consent_changed") unless permitted
      if expired?(run) || run.attempted_at.utc.beginning_of_month != Time.current.utc.beginning_of_month
        next stop_before_send(run, "expired", "stale")
      end
      if connection.month_spend_microusd > connection.monthly_budget_cents * 10_000
        next stop_before_send(run, "budget", "monthly_limit")
      end

      begin
        result = provider.call(api_key: connection.api_key, payload: payload)
      rescue AiAssistant::OpenaiClient::Error => error
        record_failure(connection, run, payload, error)
        next
      end
      answer = AiAssistant::Recipe.render(result.selection, payload.facts, kind: run.kind)
      status = if answer
        "complete"
      elsif run.kind == "test"
        "failed"
      else
        "fallback"
      end
      run.update!(status: status, answer: answer || local_answer(run, payload),
        failure_code: answer ? nil : "invalid_response", actual_microusd: result.actual_microusd,
        input_tokens: result.input_tokens, output_tokens: result.output_tokens,
        provider_request_id: result.request_id, finished_at: Time.current)
      connection.update!(status: "ready", last_verified_at: Time.current) if answer && run.kind == "test"
    end
  end

  def local_answer(run, payload)
    run.kind == "test" ? {} : AiAssistant::Recipe.fallback(payload.facts)
  end

  def record_failure(connection, run, payload, error)
    if %w[reconnect credits_exhausted].include?(error.code)
      connection.update!(status: error.code)
    end
    run.update!(status: run.kind == "test" ? "failed" : "fallback", failure_code: error.code,
      answer: local_answer(run, payload), actual_microusd: error.charge_uncertain ? nil : 0,
      provider_request_id: error.request_id, finished_at: Time.current)
  end
end
