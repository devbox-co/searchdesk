require "test_helper"
require "tempfile"

class ProjectRecordsTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = Workspace.create!(name: "Project records")
    @site = @workspace.sites.create!(name: "North", host: "north.example", location: "York")
    @user = User.create!(email: "records@example.test", password: "local-password-for-tests")
    @workspace.memberships.create!(user: @user, role: "owner")
    post login_path, params: { session: { email: @user.email, password: "local-password-for-tests" } }
    @fact = { "provider" => "gsc", "external_id" => "s1", "title" => "Query report",
      "observed_on" => "2026-01-10", "scope" => "Property and query over one day",
      "metrics" => {"average_position" => 7.6, "by_device" => {"mobile" => 10}}, "keyword" => "heating engineer" }
    @item = { "external_id" => "t1", "title" => "Review page", "status" => "proposed",
      "priority" => "high", "summary" => "Owner to review", "source_path" => "reports/tasks.json" }
  end

  test "reimports preserve owner decisions and never create ranking observations" do
    counts = ProjectImport.call(site: @site, evidence: [@fact], tasks: [@item])
    assert_equal 1, counts[:tasks][:created]
    task = @site.project_tasks.sole
    patch project_task_path(task), params: {project_task: {working_status: "waiting", owner_note: "Waiting for feedback."}}
    assert_redirected_to project_task_path(task)
    stamp = task.reload.updated_at
    counts = ProjectImport.call(site: @site, evidence: [@fact], tasks: [@item])
    assert_equal 1, counts[:evidence][:unchanged]
    assert_equal stamp, task.reload.updated_at
    counts = ProjectImport.call(site: @site, tasks: [@item.merge("status" => "verified", "summary" => "Source updated")])
    assert_equal 1, counts[:tasks][:updated]
    assert_equal ["verified", "waiting", "Waiting for feedback."], [task.reload.status, task.effective_status, task.owner_note]
    assert_equal 0, RankObservation.count
    get source_snapshots_path, params: { provider: "gsc", keyword: "Heating Engineer" }
    assert_select "article h2", text: "Query report"
    get source_snapshots_path, params: { keyword: "different" }
    assert_select "article", count: 0
    get project_tasks_path, params: { status: "waiting" }
    assert_select "article h2", text: "Review page"
    get project_tasks_path, params: { status: "verified" }
    assert_select "article", count: 0
    patch project_task_path(task), params: {project_task: {working_status: ""}}
    assert_equal "verified", task.reload.effective_status
  end

  test "validated import is atomic and rejects owner fields dangerous links malformed dates and path traversal" do
    bad_rows = [@fact.merge("observed_on" => "2026-02-30"), @fact.merge("source_path" => "../another-account.txt"),
      @fact.merge("source_url" => "javascript:alert(1)"), @fact.merge("source_url" => "https://guest@host.test/file"),
      @fact.merge("metrics" => []), @fact.merge("site_id" => @site.id)]
    bad_rows.each do |row|
      assert_raises(ProjectImport::Error) { ProjectImport.call(site: @site, evidence: [row]) }
    end
    assert_raises(ProjectImport::Error) { ProjectImport.call(site: @site, evidence: [@fact], tasks: [@item.merge("owner_note" => "Injected")]) }
    assert_raises(ProjectImport::Error) { ProjectImport.call(site: @site, evidence: [@fact, @fact]) }
    assert_empty @site.source_snapshots
    assert_empty @site.project_tasks
  end

  test "same source identity has independent tenant data and viewers cannot modify or import" do
    other = Workspace.create!(name: "Other").sites.create!(name: "South", host: "south.example", location: "Bath")
    [@site, other].each { |site| ProjectImport.call(site: site, evidence: [@fact], tasks: [@item]) }
    get source_snapshot_path(other.source_snapshots.sole)
    assert_response :not_found
    patch project_task_path(other.project_tasks.sole), params: {project_task: {owner_note: "wrong tenant"}}
    assert_response :not_found
    @user.memberships.sole.update!(role: "viewer")
    get source_snapshot_path(@site.source_snapshots.sole)
    assert_response :success
    assert_select "pre", text: /mobile/
    patch project_task_path(@site.project_tasks.sole), params: {project_task: {owner_note: "viewer"}}
    assert_response :forbidden
    get new_project_import_path
    assert_response :forbidden
    post project_imports_path
    assert_response :forbidden
    assert_nil @site.project_tasks.sole.owner_note
  end

  test "manager file import exposes usable links through the normal navigation" do
    @user.memberships.sole.update!(role: "manager")
    Tempfile.create(["records", ".json"]) do |file|
      file.write(JSON.generate(evidence: [@fact], tasks: [@item]))
      file.flush
      post project_imports_path, params: {project_import: {file: Rack::Test::UploadedFile.new(file.path, "application/json")}}
      assert_redirected_to new_project_import_path
      follow_redirect!
      assert_select "[role=status]", text: /Evidence: 1 added/
    end
    [[rankings_path, source_snapshots_path], [integrations_path, source_snapshots_path], [actions_path, project_tasks_path]].each do |from, to|
      get from
      assert_select "a[href=?]", to
    end
  end

  test "actions shows five priority project tasks, effective status counts and separate keyword filters" do
    other = Workspace.create!(name: "Separate workspace").sites.create!(name: "Elsewhere", host: "elsewhere.example", location: "Bath")
    ProjectImport.call(site: other, tasks: [@item.merge("title" => "Other site's work")])
    statuses = %w[proposed ready_for_review needs_evidence in_progress awaiting_selection blocked verified superseded proposed proposed proposed]
    records = statuses.each_with_index.map do |status, index|
      @site.project_tasks.create!(external_id: "task-#{index}", title: "Task #{index}", status: status, priority: index.zero? ? "low" : "high")
    end
    records[8].update!(working_status: "completed")
    records[9].update!(working_status: "waiting")
    get actions_path
    assert_response :success
    assert_select ".project-actions", text: /6 actionable of 11 project tasks/
    assert_select ".priority-tasks li", count: 5
    assert_select ".priority-tasks li a" do |links|
      assert_equal [1, 2, 3, 4, 10].map { |i| project_task_path(records[i]) }, links.map { |a| a["href"] }
    end
    %w[awaiting_selection blocked verified superseded completed waiting].each do |status|
      assert_select ".task-statuses a[href=?]", project_tasks_path(status: status), text: "#{status.humanize} · 1"
    end
    assert_no_match(/Other site's work/, response.body)
    assert_select "h3", text: "No open keyword recommendations in this view"
    get project_tasks_path, params: { status: "blocked" }
    assert_select "article a", text: records[5].title
    keyword = Tracking::Enrollment.call(site: @site, phrase: "heating repair")
    get actions_path, params: { keyword_id: keyword.id, state: "resolved" }
    assert_select ".project-actions", count: 0
    assert_select "h3", text: "No reviewed keyword recommendations in this view"
    assert_select "form select[name=keyword_id] option[selected]", text: keyword.phrase
  end
end
