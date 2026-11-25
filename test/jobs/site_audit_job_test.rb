require "test_helper"

class SiteAuditJobTest < ActiveJob::TestCase
  setup do
    @site = Workspace.create!(name: "Audit test").sites.create!(name: "Sample", host: "sample.example", location: "London")
  end

  test "duplicate clicks and recent completions reuse one receipt per site" do
    assert_enqueued_jobs 1, only: SiteAuditJob do
      audit = SiteAudit.request!(site: @site)
      assert_equal audit, SiteAudit.request!(site: @site)
      audit.update!(status: "complete", finished_at: Time.current)
      assert_equal audit, SiteAudit.request!(site: @site)
    end
    travel 6.minutes do
      assert_enqueued_jobs(1, only: SiteAuditJob) { SiteAudit.request!(site: @site) }
    end
    assert_equal 2, SiteAudit.where(site: @site).count
  end

  test "weekly refresh opts in per site, uses a single current sample and checks consent before starting" do
    assert_no_enqueued_jobs(only: SiteAuditJob) { SiteAuditRecoveryJob.perform_now }
    @site.update!(weekly_site_audit_enabled: true)
    assert_enqueued_jobs(1, only: SiteAuditJob) { 2.times { SiteAuditRecoveryJob.perform_now } }
    audit = SiteAudit.where(site: @site).sole
    assert_equal "weekly", audit.trigger_kind
    @site.update!(weekly_site_audit_enabled: false)
    SiteAuditJob.perform_now(audit.id)
    assert_equal "failed", audit.reload.status
    assert_match(/switched off/, audit.failure_reason)
    @site.update!(weekly_site_audit_enabled: true)
    travel 6.days do
      assert_no_enqueued_jobs(only: SiteAuditJob) { SiteAuditRecoveryJob.perform_now }
    end
    travel 5.weeks do
      assert_enqueued_jobs(1, only: SiteAuditJob) { 2.times { SiteAuditRecoveryJob.perform_now } }
      assert_equal 2, SiteAudit.where(site: @site).count
      assert_equal Time.current.to_date, SiteAudit.where(site: @site).maximum(:created_at).to_date
    end
  end

  test "worker checks bound domain and never processes a terminal receipt twice" do
    audit = SiteAudit.request!(site: @site)
    @site.update!(host: "new.example")
    SiteAuditJob.perform_now(audit.id)
    assert_equal "failed", audit.reload.status
    assert_match(/site address changed/, audit.failure_reason)
    finished = audit.finished_at
    SiteAuditJob.perform_now(audit.id)
    assert_equal finished, audit.reload.finished_at
  end

  test "recovery re-enqueues a lost delivery and retires abandoned running work" do
    audit = SiteAudit.request!(site: @site)
    travel 3.minutes do
      assert_enqueued_jobs(1, only: SiteAuditJob) { SiteAuditRecoveryJob.perform_now }
    end
    audit.update!(status: "running", started_at: 11.minutes.ago)
    assert_no_enqueued_jobs(only: SiteAuditJob) { SiteAuditRecoveryJob.perform_now }
    assert_equal "failed", audit.reload.status
    assert audit.finished_at
  end
end
