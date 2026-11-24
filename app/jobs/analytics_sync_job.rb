class AnalyticsSyncJob < ApplicationJob
  queue_as :default

  def perform(id = nil, scheduled: false)
    return unless Analytics::Client.configured?
    if id
      connection = AnalyticsConnection.find_by(id: id)
      Analytics::Synchronizer.call(connection, scheduled: scheduled) if connection
    else
      AnalyticsGrant.where("expires_at < ?", Time.current).delete_all
      AnalyticsConnection.due_for_sync.find_each { |connection| self.class.perform_later(connection.id, scheduled: true) }
    end
  end
end
