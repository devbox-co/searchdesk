class SchedulesController < ApplicationController
  def show
    now = Time.current
    @rows = Schedules::Workflows.new(site: current_site, now: now).rows +
      Schedules::Sources.new(site: current_site, now: now).rows
    monitor = Schedules::WorkerMonitor.new(now: now)
    @worker_health = monitor.health
    @system_checks = workspace_owner? ? monitor.checks : []
  end
end
