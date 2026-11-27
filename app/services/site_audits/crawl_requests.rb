module SiteAudits
  module CrawlRequests
    REDIRECTS = [301, 302, 303, 307, 308].freeze
    MIN_DELAY = 0.5
    class Stop < StandardError; end

    private

    def start_requests(request_limit:, time_limit:)
      @request_limit = request_limit
      @deadline = clock + time_limit
      @requests = 0
      @delay = MIN_DELAY
      @policies = {}
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def fetch(uri, robots: false)
      raise Stop, "Reached the request limit for this crawl." if @requests >= @request_limit
      # Leave enough time for the complete bounded network request.
      raise Stop, "Reached the time limit for this crawl." if clock + @delay + 12 > @deadline
      @sleeper.call(@delay) unless @requests.zero?
      @requests += 1
      @fetcher.get(uri, robots: robots)
    end

    def policy_for(uri)
      origin = "#{uri.scheme}://#{uri.host}"
      @policies[origin] ||= begin
        target = @scope.resolve("/robots.txt", base: origin, robots: true)
        visited = Set.new
        raise Stop, "The site address is outside the public crawl scope." unless target
        rules = loop do
          raise Stop, "Could not confirm robots.txt after redirects." unless visited.size < 6 && visited.add?(target.to_s)
          response = fetch(target, robots: true)
          case response.status
          when 200..299
            raise Stop, "Could not read robots.txt because the server returned HTML." if response.body.lstrip.start_with?("<")
            break Robots.new(response.body)
          when 404, 410
            break Robots.new("")
          when *REDIRECTS
            target = @scope.resolve(response.location, base: target, robots: true)
            raise Stop, "The robots.txt redirect left this site's crawl scope." unless target
          else
            raise Stop, "The server returned HTTP #{response.status} for robots.txt. The crawl stopped."
          end
        end
        raise Stop, "The site's requested crawl delay exceeds the audit time budget." if rules.delay > 10
        @delay = [@delay, rules.delay].max
        rules
      end
    rescue Robots::Unreadable
      raise Stop, "The robots.txt rules exceed the supported audit limits."
    rescue Fetcher::Error => error
      raise Stop, "Could not confirm robots.txt. #{error.message}"
    end
  end
end
