module AiAssistant
  class BriefSourceReading
    DATE = /\d{4}-\d{2}-\d{2}/

    def self.for(fact)
      text = fact["text"].to_s
      case fact["source"]
      when "Weekly search clicks" then weekly_clicks(text)
      when "Google Search Console" then search_console(text)
      when "Local Falcon" then maps(text)
      when "Google Analytics 4" then traffic(text)
      when "Google Business Profile via Local Falcon" then business_profile(text)
      when "Semrush Position Tracking" then campaign(text)
      when "Project tasks" then project_task(text)
      when "Source availability" then availability(text)
      end
    end

    def self.comparison(facts)
      return unless facts.is_a?(Array) && facts.size == 2 && facts.all? { |fact| fact.is_a?(Hash) }
      source = facts.first["source"]
      return unless source == facts.last["source"]

      periods = facts.map { |fact| comparable_period(source, fact) }
      return if periods.any?(&:nil?)
      previous, current = periods.sort_by { |period| period[:start] }
      return unless previous[:scope] == current[:scope] && current[:start] == previous[:finish] + 1

      before, after = previous[:value], current[:value]
      direction = if after == before
        "held steady"
      else
        after > before ? "rose" : "fell"
      end
      noun, label = source == "Google Search Console" ? ["click", "Clicks from Google search"] : ["visit", "Visits from Google search"]
      meaning = "There were #{count(after, noun)} in four weeks, compared with #{before} in the previous four weeks."
      meaning += " Google flagged limits on the visit figures." if periods.any? { |period| period[:limited] }
      reading("#{label} #{direction}", meaning, priority: 52).merge(action_fact: current[:fact])
    end

    class << self
      private

      def reading(headline, meaning, action: nil, priority: 65)
        { headline: headline, meaning: meaning, action: action, priority: priority }
      end

      def comparable_period(source, fact)
        text = fact["text"].to_s
        data = case source
        when "Google Search Console"
          text.match(/\AGoogle web search, all countries and devices, (?<start>#{DATE}) through (?<finish>#{DATE}) recorded (?<value>\d+) clicks and \d+ impressions\.\z/)
        when "Google Analytics 4"
          text.match(/\AGoogle \/ organic traffic for (?<host>[^, ]+), (?<start>#{DATE}) through (?<finish>#{DATE}) recorded (?<value>\d+) sessions, \d+ engaged sessions\. Key events are unvalidated as enquiries\.(?: Google flagged sampling, thresholds or aggregation limits\.)?\z/)
        end
        return unless data

        start, finish = Date.iso8601(data[:start]), Date.iso8601(data[:finish])
        return unless finish - start == 27
        scope = source == "Google Analytics 4" ? data[:host] : source
        { start: start, finish: finish, value: data[:value].to_i, scope: scope, fact: fact, limited: text.include?("Google flagged") }
      rescue Date::Error
        nil
      end

      def weekly_clicks(text)
        coverage = text.match(/(\d+) of (\d+) tracked search(?:es)? had reported click counts on all 14 days\./)
        return unless coverage
        complete, total = coverage.captures.map(&:to_i)
        return unless total.positive? && complete <= total
        if complete.zero?
          return reading("A weekly click comparison isn’t available yet", "None of the tracked searches had figures for both full weeks.",
            action: "Check again after the next Google update.")
        end

        changes = text.scan(/“([^”]+)” (rose|fell) from (\d+) to (\d+) clicks\./)
        coverage_note = "#{complete} of #{total} tracked searches had enough data to compare."
        if (example = changes.max_by { |_term, _direction, before, after| (after.to_i - before.to_i).abs })
          term, direction, before, after = example
          reading("Clicks #{direction} for “#{term}”", "Weekly clicks went from #{before} to #{after}. #{coverage_note}",
            action: "Check whether the change lasts another week before editing a page.", priority: 55)
        elsif text.include?("Weekly clicks held steady")
          reading("Weekly clicks held steady for the searches we could compare", coverage_note)
        end
      end

      def search_console(text)
        if (m = text.match(/\AGoogle web search, all countries and devices, #{DATE} through #{DATE} recorded (\d+) clicks and \d+ impressions\./))
          return reading("People found your website through Google", "Your site received #{m[1]} search clicks across all countries in this four-week period.") unless m[1] == "0"
          return reading("Google recorded no search clicks in this period", "This covers four weeks of web searches across all countries and devices.")
        end
        if (m = text.match(/\A(.+?), #{DATE}, [A-Z]{2,3}, Google web search, all devices, (?:final API|imported report) — [^,]+, (\d+) impressions and (\d+) clicks\./))
          return reading("Search activity for “#{m[1]}”", "On the measured day, Google showed the site #{times(m[2])} for this search and recorded #{count(m[3], 'click')}.")
        end
        if text.match?(/\AGoogle web search, all countries and devices, #{DATE} through #{DATE} recorded no matching rows\./)
          reading("Google returned no site totals", "Search Console has no figures for this four-week period.")
        end
      end

      def maps(text)
        term = text[/\A(.+?), Google Maps scan for /, 1]
        result = text.match(/Top three on (\d+) of (\d+) pins\./)
        return unless term && result
        top, total = result.captures.map(&:to_i)
        return unless total.positive? && top <= total
        meaning = "Your business appeared in the first three Maps results at #{top} of #{count(total, 'location')} checked."
        if (pair = text.match(/on \d+ matched pins, gained top-three on (\d+) and lost it on (\d+)\./))
          difference = pair[1].to_i - pair[2].to_i
          if difference != 0
            meaning += " Compared with the earlier scan, that’s #{difference.abs} #{difference.positive? ? 'more' : 'fewer'} among the locations checked both times."
          end
        end
        reading("Google Maps visibility for “#{term}”", meaning, action: "Open the map to see which locations reached the first three results.", priority: 55)
      end

      def traffic(text)
        if (m = text.match(/\AGoogle organic sessions were (?:unchanged|\d+ (?:higher|lower)) in the 28 days through #{DATE} \((\d+)\) compared with the preceding 28 days through #{DATE} \((\d+)\)\./))
          now, before = m.captures.map(&:to_i)
          direction = now == before ? "held steady" : (now > before ? "rose" : "fell")
          return reading("Visits from Google #{direction}", "Google organic search accounted for #{count(now, 'visit')} over four weeks, compared with #{before} in the previous four.", priority: 55)
        end
        if (m = text.match(/\AGoogle \/ organic traffic for .+?, #{DATE} through #{DATE} recorded (\d+) sessions,/))
          caveat = " Google flagged limits on these figures." if text.include?("Google flagged")
          return reading("Visits from Google search", "Google Analytics recorded #{count(m[1], 'visit')} from unpaid search over four weeks.#{caveat}")
        end
        if text.match?(/\AGoogle \/ organic traffic for .+?, #{DATE} through #{DATE} recorded no matching rows\./)
          reading("Google Analytics returned no traffic figures", "There’s no visit total for unpaid Google search in this four-week period.")
        end
      end

      def business_profile(text)
        items = text.match(/\ABusiness Profile interactions, #{DATE} through #{DATE} included (.+?)\. Qualified enquiries are unverified\./)
        return unless items
        measured = items[1].scan(/(\d+) (website clicks|call clicks|direction requests)/)
        return if measured.empty?
        n, label = measured.max_by { |value, _label| value.to_i }
        unit = { "website clicks" => "click on the website link", "call clicks" => "click on the call button", "direction requests" => "request for directions" }.fetch(label)
        activity = n == "1" ? unit : unit.sub(/\A\w+/) { |word| "#{word}s" }
        reading("Activity on your Google Business Profile", "Google recorded #{n} #{activity} in four weeks. Enquiries still need to be confirmed.")
      end

      def campaign(text)
        m = text.match(/\A(.+?), #{DATE}, .+?, (mobile|desktop) — position (\d+) in Semrush's feature-inclusive campaign\./)
        return unless m
        original = text[/Numeric baseline (\d+) on #{DATE}\./, 1]
        meaning = original ? "The saved #{m[2]} ranking went from #{original} to #{m[3]} since tracking started." : "The saved #{m[2]} ranking was #{m[3]}."
        reading("Campaign ranking for “#{m[1]}”", meaning)
      end

      def project_task(text)
        m = text.match(/\A“(.+)” is a (\w+) priority project task\. Its current status is (.+)\.\z/)
        return unless m
        title, level, status = m.captures
        priority = %w[critical urgent high].include?(level) ? 30 : 60
        if title.match?(/\b(?:validate|verify|confirm|check)\b.{0,35}\b(?:enquiry|lead)\s+(?:measurement|tracking)\b/i)
          return reading("Check how enquiries are counted", "Your project has an open task to verify which website actions count as genuine enquiries.",
            action: "Compare a recorded enquiry with your business records to check that it was counted correctly.", priority: priority)
        end
        step = case status
        when "needs evidence" then "Open the task and check what evidence is missing."
        when "ready for review", "awaiting selection" then "Open the task and review the proposed change."
        else "Open the task to review the next step."
        end
        reading(title, "Your project lists this as a #{level}-priority task.", action: step, priority: priority)
      end

      def availability(text)
        if (m = text.match(/\A(.+?) · No eligible saved readings for this scope through #{DATE}\.\z/))
          reading("No saved figures from #{m[1]}", "This source has no reading that matches this review.", priority: 80)
        elsif (m = text.match(/\A(.+?) · Sharing with the assistant is off for this site\.\z/))
          reading("#{m[1]} is outside this review", "The site’s sharing settings exclude this source.", priority: 80)
        end
      end

      def count(n, noun)
        "#{n} #{n.to_i == 1 ? noun : "#{noun}s"}"
      end

      def times(n)
        return "once" if n == "1"
        "#{n} times"
      end
    end
  end
end
