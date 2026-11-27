class CompetingPageSyncJob < ApplicationJob
  queue_as :default

  def perform(connection_id)
    return unless SearchConsole::Client.configured?
    connection = SearchConsoleConnection.find_by(id: connection_id)
    SearchConsole::CompetingPageSync.call(connection) if connection
  end
end
