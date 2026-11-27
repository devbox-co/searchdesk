module AssistantsHelper
  def ai_connection_label(connection)
    return "Not connected" unless connection&.configured?
    return "Allowance paused" if connection.monthly_budget_cents.zero?
    return "Budget reached" if connection.month_spend_microusd >= connection.monthly_budget_cents * 10_000
    { "ready" => "Ready", "untested" => "Test required", "reconnect" => "Reconnect",
      "credits_exhausted" => "Credits exhausted" }.fetch(connection.status, "Test required")
  end

  def ai_run_label(run)
    { "pending" => "Queued", "running" => "Preparing", "complete" => "Complete", "fallback" => "Local evidence",
      "failed" => "Unavailable", "budget" => "Budget reached", "expired" => "Expired", "cancelled" => "Cancelled" }.fetch(run.status, "Unavailable")
  end

  def ai_account_guidance(label)
    {
      "Not connected" => "Connect an OpenAI project and choose a monthly allowance.",
      "Allowance paused" => "Set a positive monthly allowance to enable paid requests.",
      "Test required" => "Run a connection test to verify the saved key.",
      "Reconnect" => "Check the project key and its Responses write permission, then test the connection.",
      "Credits exhausted" => "Check the OpenAI organization’s API credit balance and the organization or project usage limits, then test again.",
      "Budget reached" => "The workspace has used its allowance. Review the limit or wait for the next UTC calendar month."
    }[label]
  end

  def ai_failure_guidance(run)
    case run.failure_code
    when "uncertain" then "The worker stopped before recording the result. The estimated charge remains reserved."
    when "model_unavailable" then "Check that the billing project can use the selected model."
    when "rate_limited" then "OpenAI temporarily limited requests. Try again later."
    when "reconnect" then ai_account_guidance("Reconnect")
    when "credits_exhausted" then ai_account_guidance("Credits exhausted")
    when "monthly_limit" then "This request would exceed the workspace allowance. Review the limit or wait for the next UTC calendar month."
    when "stale" then "The request expired before it could finish."
    when "consent_changed" then "The account or site permissions changed before the request finished."
    else "Check the OpenAI account status and the workspace allowance before trying again."
    end
  end

  def ai_run_title(run)
    return "OpenAI connection test" if run.kind == "test"
    if run.kind == "page_advice"
      review = run.site_finding.evidence
      return "Page recommendation · #{review.fetch('query')} · #{review.fetch('device').capitalize}"
    end
    if run.kind == "brief"
      title = "Daily brief · #{run.report_on&.strftime('%d %b %Y')}"
      return run.request_key == "brief/#{run.report_on}/#{run.recipe_version}" ? "#{title} · Updated" : title
    end
    run.question.presence || "Question"
  end

  def ai_brief_origin(brief)
    label, icon = brief.status == "complete" ? ["Prepared by Searchdesk AI", :sparkles] : ["Built from local evidence", :evidence]
    tag.span(class: "brief-origin") do
      safe_join([ui_icon(icon, size: 16), label], " ")
    end
  end

  def ai_citation(fact, label: nil)
    label ||= [fact["id"], fact["source"]].compact.join(" · ")
    url = fact["url"].to_s
    # Only the app's server-side evidence routes may be clickable.
    allowed = %r{\A/(?:rankings|keywords|actions|project_tasks|source_snapshots|search_console|analytics|local_falcon_connection|integrations|assistant)(?:[/?#]|\z)}
    return tag.span(label) if url == assistant_settings_path && !workspace_owner?
    if allowed.match?(url) && !url.match?(/[\\[:cntrl:]]/)
      link_to label, url
    else
      tag.span(label)
    end
  end

  def ai_local_datetime(time)
    time&.in_time_zone(current_site.time_zone)&.strftime("%d %b %Y, %H:%M %Z")
  end
end
