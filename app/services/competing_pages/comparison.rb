module CompetingPages
  class Comparison
    MIN_LEADER_IMPRESSIONS = 5
    MIN_LEAD = 2

    def self.public_page(value, host)
      return unless value.is_a?(String) && value.bytesize <= 4096 && !value.match?(/[\\[:cntrl:]]/)
      uri = Tracking::ResultUrl.parse(value)
      return unless uri && uri.port == uri.default_port && !uri.query && Tracking::ResultUrl.host_matches?(host, uri.host)
      uri.host = uri.host.downcase
      uri.fragment = nil
      uri.path = "/" if uri.path.empty?
      uri.to_s
    end

    def self.latest_switch(timeline, pair)
      timeline.each_cons(2).reverse_each do |previous, current|
        from, to = previous["leader_url"], current["leader_url"]
        next unless previous["state"] == "leader" && current["state"] == "leader"
        next unless from != to && pair.include?(from) && pair.include?(to)
        next unless Date.iso8601(previous.fetch("week_start")) + 7 == Date.iso8601(current.fetch("week_start"))

        return { from: from, to: to, week_start: current.fetch("week_start") }
      end
      nil
    end

    def initialize(host:, weeks:, reports:)
      @host, @weeks = host, weeks
      @reports = reports.index_by(&:week_start)
    end

    def call
      timeline = @weeks.map { |date| weekly_result(date, @reports[date]) }
      impressions = Hash.new(0)
      observed = Set.new
      timeline.each do |week|
        week.fetch("pages").each do |page|
          url = page.fetch("url")
          observed << url
          impressions[url] += page.fetch("impressions") unless week["state"] == "partial"
        end
      end
      return unless observed.size >= 2

      leaders = timeline.pluck("leader_url")
      # Only an observed change between adjacent clear leaders can introduce a swapping pair.
      candidates = leaders.each_cons(2).filter_map { |a, b| [a, b].sort if a && b && a != b }.uniq
      most_visible = observed.sort_by { |url| [-impressions[url], url] }.first(2).sort
      candidates |= [most_visible]
      pair, switches = candidates.map { |pages| [pages, longest_switch_count(pages, leaders)] }.min_by do |pages, count|
        [count >= 2 && !alias_candidates?(*pages) ? 0 : 1, -count, -pages.sum { |url| impressions[url] }, pages]
      end
      comparable_weeks = leaders.count { |leader| pair.include?(leader) }
      level = if alias_candidates?(*pair)
        "limited"
      elsif switches >= 2
        "review"
      elsif comparable_weeks >= 2 && pair.all? { |url| impressions[url] >= MIN_LEADER_IMPRESSIONS }
        "watch"
      else
        "limited"
      end
      clicks = click_comparison(timeline)
      if level == "watch" && switches == 1
        # A later tied, missing or third-page week need not have the same leader.
        last_switch = self.class.latest_switch(timeline, pair)
      end
      { "rule_version" => 1, "level" => level, "pages" => pair, "switch_count" => switches,
        "weeks" => timeline, "clicks" => clicks, "recommended_page_url" => last_switch&.fetch(:to),
        "recommendation" => recommendation(level, pair, clicks, switches) }
    end

    private

    def weekly_result(date, receipt)
      # GSC can omit privacy-filtered or low-volume rows. An explicitly returned
      # zero is evidence; an absent query/device row is unknown.
      result = { "week_start" => date.iso8601, "state" => "unreported", "leader_url" => nil,
        "clicks" => nil, "impressions" => nil, "pages" => [] }
      return result unless receipt
      # The collector reads the property total separately. Truncating or rejecting
      # a page row makes the leader uncertain but does not invalidate this total.
      result["clicks"] = receipt.clicks
      result["impressions"] = receipt.impressions
      pages = receipt.pages.filter_map do |row|
        url = self.class.public_page(row["url"], @host)
        row.slice("clicks", "impressions", "position").merge("url" => url) if url && row["impressions"].to_i.positive?
      end.sort_by { |page| [-page["impressions"], page["url"]] }
      result["pages"] = pages.uniq { |p| p["url"] }
      if receipt.partial || pages.size != receipt.pages.size || result["pages"].size != pages.size
        return result.merge("state" => "partial")
      end
      return result if pages.empty?

      top = pages.first
      runner_up = pages.second&.fetch("impressions") || 0
      # A one-impression wobble at either five or five hundred impressions
      # should not change the weekly leader. A tie interrupts the sequence.
      difference = top["impressions"] - runner_up
      if top["impressions"] < MIN_LEADER_IMPRESSIONS
        result["state"] = "sparse"
      elsif difference < [MIN_LEAD, (top["impressions"] * 0.1).ceil].max
        result["state"] = "tie"
      else
        result.merge!("state" => "leader", "leader_url" => top.fetch("url"))
      end
      result
    end

    def longest_switch_count(pair, leaders)
      best = 0
      count = 0
      previous = nil
      leaders.each do |leader|
        if pair.include?(leader)
          count += 1 if previous && previous != leader
          previous = leader
          best = [best, count].max
        else
          previous = nil
          count = 0
        end
      end
      best
    end

    def alias_candidates?(left, right)
      # Protocol, www and trailing-slash variants may resolve to one resource.
      # Keep both raw observations, but request canonical verification first.
      a, b = [left, right].map { |url| URI.parse(url) }
      Tracking::ResultUrl.host_matches?(a.host, b.host) && a.path.delete_suffix("/") == b.path.delete_suffix("/")
    end

    def click_comparison(timeline)
      periods = timeline.each_slice(4).to_a
      previous, current = periods.map { |weeks| known_total(weeks, "clicks") }
      previous_impressions, current_impressions = periods.map { |weeks| known_total(weeks, "impressions") }
      change = current - previous if current && previous
      trend = case change
      when nil then "unknown"
      when 0 then "flat"
      else change.positive? ? "up" : "down"
      end
      material_decline = previous.to_i >= 10 && change && -change >= [3, (previous * 0.2).ceil].max
      { "previous" => previous, "current" => current, "change" => change, "trend" => trend,
        "material_decline" => !!material_decline,
        "previous_impressions" => previous_impressions, "current_impressions" => current_impressions,
        "previous_start" => @weeks.first.iso8601, "previous_end" => (@weeks[3] + 6).iso8601,
        "current_start" => @weeks[4].iso8601, "current_end" => (@weeks.last + 6).iso8601 }
    end

    def known_total(weeks, field)
      values = weeks.pluck(field)
      values.sum if values.none?(&:nil?)
    end

    def recommendation(level, pair, clicks, switches)
      if alias_candidates?(*pair)
        "Ask your developer whether both addresses lead to the same page. Check redirects and the preferred address before considering an edit."
      elsif level == "limited"
        "Keep monitoring these pages. There is too little comparable evidence to recommend changing either page."
      elsif level == "watch"
        watch_recommendation(switches, clicks)
      elsif clicks["trend"] == "down"
        "Review both pages first. Decide which best answers this search. If the other page serves a different need, keep both and check whether a helpful link already connects them. Also check for changes in search demand."
      else
        "Check what a visitor needs from each page. Keep both if they serve different purposes. If they answer the same need, choose the preferred page and ask for one proposed improvement."
      end
    end

    def watch_recommendation(switches, clicks)
      if switches.zero?
        if clicks["trend"] == "down"
          return falling_clicks_without_switches(clicks)
        end
        return "Keep both pages in place and check which leads next week. If the pages serve different needs, you can mark the overlap as expected."
      end

      action = "Open the page that took the lead and check whether it answers this search."
      if clicks["trend"] == "down" && clicks["previous"] < 10
        "#{action} With so few clicks, wait for next week’s results before changing either page."
      elsif clicks["trend"] == "down"
        "#{action} Compare search appearances and clicks in Search Console, then check which page leads next week."
      else
        "#{action} If it does, keep both pages in place and check which leads next week."
      end
    end

    def falling_clicks_without_switches(clicks)
      before, after = clicks.values_at("previous_impressions", "current_impressions")
      if before.nil? || after.nil?
        "Leave both pages as they are for now. In Search Console, check whether your site appeared less often for this search or whether fewer people clicked when it appeared."
      elsif after < before
        "Your site appeared less often for this search. Check whether fewer people searched for it or whether your position changed. Review next week’s figures before editing either page."
      else
        appearances = after > before ? "more often" : "just as often"
        "Your site appeared #{appearances} and received fewer clicks. Read the leading page’s title and description in Google. Do they make it clear how the page answers this search?"
      end
    end
  end
end
