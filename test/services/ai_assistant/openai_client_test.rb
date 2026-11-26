require "test_helper"

class OpenaiClientTest < ActiveSupport::TestCase
  def completed_response(selection, usage = { "input_tokens" => 300, "output_tokens" => 100 })
    { status: "completed", output: [{ type: "message", role: "assistant",
      content: [{ type: "output_text", text: selection.to_json }] }], usage: usage }.to_json
  end

  test "the text-only request omits internal metadata, tools and provider retention and bounds its full input" do
    facts = (1..50).map { |i| { "id" => "F#{i}", "text" => ("測定" * 300), "source" => "Sample",
      "url" => "/private-ui-link", "private" => "private provenance" } }
    prepared = AiAssistant::OpenaiClient.prepare(kind: "question", question: "What changed?", evidence: {
      "facts" => facts, "access" => "private provenance"
    })
    json = JSON.parse(prepared.json)
    assert_equal false, json["store"]
    assert_equal "default", json["service_tier"]
    assert_equal true, json.dig("text", "format", "strict")
    assert_nil json["tools"]
    assert_includes json.fetch("input"), "What changed?"
    refute_includes prepared.json, "private"
    assert_operator prepared.json.bytesize, :<=, AiAssistant::OpenaiClient::MAX_BYTES
    assert_operator prepared.facts.length, :<, facts.length
    assert_operator prepared.reservation_microusd, :>=, prepared.json.bytesize * 0.25 + json["max_output_tokens"] * 0.5
  end

  test "validates each cited ID and restricts the model to supported checks" do
    facts = [{ "id" => "F1", "text" => "First mobile baseline on 1 July.", "source" => "Manual import" }]
    choices = {"findings" => [{"fact_ids" => ["F1"], "next_check" => "compare_later"}]}
    answer = AiAssistant::Recipe.render(choices, facts, kind: "question")
    assert_match(/First mobile baseline.*next complete reading/, answer.dig("findings", 0, "text"))
    choices["findings"][0]["next_check"] = "confirm_enquiry"
    assert_equal facts.first["text"], AiAssistant::Recipe.render(choices, facts, kind: "question").dig("findings", 0, "text")
    choices["findings"][0]["fact_ids"] = ["unknown"]
    assert_nil AiAssistant::Recipe.render(choices, facts, kind: "question")
    assert_nil AiAssistant::Recipe.render({"findings" => []}, facts, kind: "test")
    assert_nil AiAssistant::Recipe.render({"findings" => [{"fact_ids" => ["F1"], "next_check" => "none", "text" => "Invented"}]}, facts, kind: "brief")
  end

  test "reconciles cached input and all billable output and requires a completed message" do
    usage = { "input_tokens" => 1000, "output_tokens" => 200, "input_tokens_details" => {
      "cached_tokens" => 400, "cache_write_tokens" => 200, "cache_write_tokens_details" => { "ttl_30m_tokens" => 100, "ttl_12h_tokens" => 100 }
    } }
    selection = {"findings" => []}
    client = AiAssistant::OpenaiClient.new
    body = completed_response(selection, usage)
    result = client.parse_response(200, body, "req_123")
    assert_equal [selection, 1000, 200, 182, "req_123"], result.deconstruct
    early = client.parse_response(200, body.sub("completed", "incomplete"), "unsafe receipt !")
    assert_nil early.selection
    assert_equal 182, early.actual_microusd
    assert_nil early.request_id
    bad_usage = client.parse_response(200, completed_response(selection, { "input_tokens" => -1, "output_tokens" => 3 }), nil)
    assert_nil bad_usage.actual_microusd
  end

  test "sanitizes provider errors and distinguishes credit exhaustion from retryable throttling" do
    client = AiAssistant::OpenaiClient.new
    [[429, "insufficient_quota", "credits_exhausted", false], [429, "credit_balance_exhausted", "credits_exhausted", false],
      [429, "project_spend_limit_exceeded", "credits_exhausted", false], [429, "rate_limit_exceeded", "rate_limited", false],
      [401, "invalid_api_key", "reconnect", false], [500, "", "unavailable", true]].each do |status, code, expected, uncertain|
      err = assert_raises(AiAssistant::OpenaiClient::Error) { client.parse_response(status,
        { error: { code: code, message: "secret diagnostic" } }.to_json, "req_safe") }
      assert_equal expected, err.code
      assert_equal uncertain, err.charge_uncertain
      refute_includes err.message, "secret"
    end
  end
end
