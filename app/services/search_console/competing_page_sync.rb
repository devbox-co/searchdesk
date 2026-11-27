module SearchConsole
  class CompetingPageSync
    WEEKS = 8
    TERM_LIMIT = 100
    GROUP_SIZE = 10
    LEASE = 20.minutes
    class Cancelled < StandardError; end

    def self.call(connection, client: Client.new)
      new(connection, client).call
    end

    def self.tracked_keywords(site)
      site.keywords.order(priority: :desc, phrase: :asc, id: :asc).limit(TERM_LIMIT)
    end

    def self.latest_week(data_through, now: Time.current)
      return unless data_through
      through = [data_through, now.in_time_zone(DailyPositions::ZONE).yesterday.to_date].min
      (through + 1).beginning_of_week(:monday) - 7
    end

    def initialize(connection, client)
      @connection = connection
      @site = connection.site
      @client = client
      @claim = SecureRandom.uuid
    end

    def call
      claimed = claim_run
      return true if claimed == :cached
      return false unless claimed
      reader = PageWeekReader.new(client: @client, host: @host, property: @property, country: @country, token: method(:token_for_request))
      @due.each do |week, queries|
        queries.each_slice(GROUP_SIZE) do |terms|
          receipts = reader.read(terms, week)
          with_current_binding do
            rows = receipts.reject { |row| @retained.include?([week, row[:query], row[:device]]) }
              .map { |row| row.merge(site_id: @site.id, property: @property, country: @country) }
            SearchConsolePageWeek.upsert_all(rows, unique_by: :unique_search_console_page_week)
          end
        end
      end
      with_current_binding do
        SearchConsolePageWeek.where(site_id: @site.id).where("week_start < ?", 13.months.ago.to_date).delete_all
        CompetingPages::Evaluator.call(site: @site, property: @property, country: @country)
        @connection.update!(page_week_sync_key: nil, page_week_synced_at: Time.current, page_week_error: nil)
      end
      true
    rescue Cancelled, ActiveRecord::RecordNotFound
      false
    rescue Client::Error, KeyError, TypeError, ArgumentError, ActiveRecord::RecordInvalid => error
      message = error.is_a?(Client::Error) ? error.message : "Google returned an incomplete weekly page report."
      @connection.class.where(id: @connection.id, page_week_sync_key: @claim).update_all(page_week_error: message)
      false
    ensure
      @connection.class.where(id: @connection.id, page_week_sync_key: @claim).update_all(page_week_sync_key: nil)
    end

    private

    def claim_run
      @site.with_lock do
        @connection.with_lock do
          @property = @connection.property
          @host = @site.host
          @country = DailyPositions.country_for(@site)
          return false unless @connection.status == "connected" && @connection.refresh_token.present? && @connection.data_through &&
            @country && Client.matches?(@property, @host)
          return false if @connection.page_week_sync_key && @connection.page_week_attempted_at&.after?(LEASE.ago)
          return false if @connection.page_week_error && @connection.page_week_attempted_at&.after?(1.hour.ago)
          latest = self.class.latest_week(@connection.data_through)
          @weeks = (0...WEEKS).map { |back| latest - back * 7 }
          @terms = self.class.tracked_keywords(@site).pluck(:phrase).map(&:downcase).uniq
          if @terms.empty?
            SiteFinding.competing_pages.current.where(site_id: @site.id).update_all(active: false, updated_at: Time.current)
            return false
          end
          @retained = SearchConsolePageWeek.where(site_id: @site.id, property: @property, country: @country,
            week_start: @weeks, query: @terms, device: SearchConsolePageWeek::DEVICES)
            .where("partial = FALSE OR updated_at > ?", 1.day.ago).pluck(:week_start, :query, :device).to_set
          @due = @weeks.index_with do |week|
            @terms.reject { |query| SearchConsolePageWeek::DEVICES.all? { |device| @retained.include?([week, query, device]) } }
          end
          if @due.values.all?(&:empty?) && @connection.page_week_synced_at && @connection.page_week_error.nil? &&
              !@connection.page_week_attempted_at&.after?(@connection.page_week_synced_at)
            # Priorities, preferred pages and the selected country can change between imports.
            CompetingPages::Evaluator.call(site: @site, property: @property, country: @country)
            return :cached
          end
          @revision = @connection.ai_grant_revision
          @connection.update!(page_week_sync_key: @claim, page_week_attempted_at: Time.current)
        end
      end
      true
    end

    def token_for_request
      @site.reload
      @connection.reload
      check_binding!
      if @connection.access_token.present? && @connection.token_expires_at&.after?(2.minutes.from_now)
        return @connection.access_token
      end

      refreshed = @client.refresh(@connection.refresh_token)
      with_current_binding do
        @connection.update!(access_token: refreshed.fetch("access_token"), token_expires_at: Time.current + Integer(refreshed.fetch("expires_in")).seconds)
        @connection.access_token
      end
    end

    def with_current_binding
      @site.with_lock do
        @connection.with_lock do
          check_binding!
          yield
        end
      end
    end

    def check_binding!
      unless @connection.page_week_sync_key == @claim && @connection.status == "connected" &&
          @connection.property == @property && @connection.ai_grant_revision == @revision &&
          @site.host == @host && DailyPositions.country_for(@site) == @country
        raise Cancelled
      end
    end
  end
end
