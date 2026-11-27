class SearchConsoleSyncJob < ApplicationJob
  queue_as :default

  def perform(connection_id = nil, scheduled: false)
    return unless SearchConsole::Client.configured?
    if connection_id
      connection = SearchConsoleConnection.find_by(id: connection_id)
      if connection && SearchConsole::Synchronizer.call(connection, scheduled: scheduled)
        CompetingPageSyncJob.perform_later(connection.id) if SearchConsole::DailyPositions.country_for(connection.site)
      end
    else
      SearchConsoleGrant.where("expires_at < ?", Time.current).delete_all
      SearchConsoleConnection.due_for_sync.find_each { |connection| self.class.perform_later(connection.id, scheduled: true) }
    end
  end
end
