module AiAssistant
  # Reads the stable wording of local ranking receipts, including saved briefs
  # that predate the owner-facing summary. Only interpret recognised templates.
  class BriefRankingReading
    ORGANIC = ["DataForSEO", "Manual import", "Simulated demonstration"].freeze
    DATE = /\d{4}-\d{2}-\d{2}/
    DEVICES = /desktop and mobile|desktop|mobile/
    ACTIVITY = /preferred-page checks|checks for sustained rank drops/

    class << self
      def for(fact)
        text = fact["text"].to_s
        source = fact["source"]
        return keyword_action(text) if source == "Keyword actions"
        return unless ORGANIC.include?(source)

        result = text.start_with?("On ") ? coverage(text) : individual(text)
        if result && source == "Simulated demonstration"
          result[:headline] = "Demo · #{result[:headline]}"
          result[:action] = "Explore this example in the demo rankings."
        end
        result
      end

      private

      def coverage(text)
        pattern = /\AOn #{DATE} in .+?, Google organic tracking on (?:#{DEVICES}) covered (\d+) keyword-device checks? across \d+ keywords?\. \d+ numeric positions, \d+ verified outside the top \d+, (\d+) incomplete\. .*?\d+ usable baselines\. ([^.]+)\./
        match = pattern.match(text)
        return unless match
        total, incomplete = match.captures.first(2).map(&:to_i)
        return unless total.positive? && incomplete <= total
        movement = match[3].downcase
        counts = {}
        unless movement == "movement needs observations on two comparable dates"
          movement.split(", ").each do |item|
            pair = /\A(\d+) (up|down|unchanged|entered|left|outside both)\z/.match(item)
            return unless pair && !counts.key?(pair[2])
            counts[pair[2]] = pair[1].to_i
          end
        end
        counts.default = 0
        return if counts.values.sum > total - incomplete
        gains = counts["up"] + counts["entered"]
        drops = counts["down"] + counts["left"]
        headline, meaning = if drops + gains > 0
          title = if drops > gains
            "More local rankings fell than rose"
          elsif gains > drops
            "More local rankings rose than fell"
          else
            "Local rankings moved in both directions"
          end
          [title, "Compared with their starting positions, #{drops} checks were lower and #{gains} were higher."]
        elsif counts["unchanged"].positive?
          ["The measured positions held steady", "The positions we could compare matched their starting positions."]
        elsif counts["outside both"].positive?
          ["Some searches remain outside the tracked results", "Those searches were outside the checked positions both times."]
        else
          ["It’s too early to tell how rankings changed", "A trend needs two complete checks for the same search and device."]
        end
        if incomplete * 2 > total
          meaning += " More than half the checks were incomplete, so the overall picture is still uncertain."
        elsif incomplete.positive?
          meaning += " #{incomplete} of #{total} checks were incomplete."
        end
        reading(headline, meaning, "Check the next complete results before changing a page.", incomplete.positive? ? 40 : 60)
      end

      def individual(text)
        match = /\A“([^”]+)” had a (desktop|mobile) Google organic check in .+? on (#{DATE}) \(([^)]+)\)\./.match(text)
        return unless match
        term, device, day, observation = match.captures
        subject = "“#{term}” on #{device}"
        scope = "for “#{term}” on #{device}"
        monitor = "Look at the next result #{scope} before making changes."
        case observation
        when /\Aincomplete coverage through \d+, without an exact rank\z/
          return reading("The position of #{subject} is still unknown", "The check ended before it could establish a position.", monitor, 40)
        when /\A(?:pending|missing|failed|paused|not enrolled|reserved|submitted|collecting), with no reading\z/
          return reading("No result for #{subject}", "This check has no measured position to compare.", monitor, 40)
        end

        baseline = /\. The baseline on (#{DATE}) was (position \d+|outside the top \d+)\./.match(text)
        earlier = baseline && baseline[1] < day
        if (outside = /\Averified outside the top (\d+)\z/.match(observation))
          meaning = "Your site was outside the first #{outside[1]} results in this check."
          return reading("#{subject} was outside the top #{outside[1]}", meaning, monitor, 60)
        end
        position = /\Aranked at position (\d+)\z/.match(observation)
        return unless position
        current = position[1].to_i
        return unless current.positive?
        title = "Your site ranked #{ordinal(current)} for #{subject}"
        meaning = "This is a starting point for future checks."
        priority = 60
        if earlier && baseline[2].start_with?("position ")
          first = baseline[2].split.last.to_i
          return unless first.positive?
          if first == current
            meaning = "It held its starting position."
          else
            direction = current > first ? "fell" : "rose"
            title = "“#{term}” #{direction} on #{device}"
            meaning = "Your site moved from #{ordinal(first)} to #{ordinal(current)} since tracking began."
            priority = 20 if current > first
          end
        elsif earlier
          meaning = "The first check placed your site #{baseline[2]}."
        end
        pages = %r{\. Winning page (/\S*)\. Preferred page (/\S*)\.\z}.match(text)
        if pages && pages[1] != pages[2]
          meaning += " Google showed a different page from the one you chose for this search."
          target = pages[2] == "/" ? "your homepage" : "the page you chose"
          return reading(title, meaning, "Compare the page Google showed for “#{term}” with #{target}. Which better answers that search?", 10)
        end
        reading(title, meaning, monitor, priority)
      end

      def keyword_action(text)
        if (example = /\A“([^”]+)” has (#{ACTIVITY}) on ((?:desktop|mobile) on #{DATE}(?:, (?:desktop|mobile) on #{DATE})*)\./.match(text))
          term, activity, scope = example.captures
          devices = scope.scan(/desktop|mobile/).uniq.join(" and ")
          if activity == "preferred-page checks"
            return reading("Check which page appears for “#{term}”", "On #{devices}, Google showed a different page from the one you chose for this search.",
              "Compare the two pages for “#{term}”. Which one best answers what the person searched for?", 10)
          end
          return reading("“#{term}” has ranked lower for two days", "On #{devices}, it was below its starting position on two consecutive checks.",
            "Open the ranking history for “#{term}” and review the page that appeared.", 20)
        end
        group = /\A\d+ currently open device readings for (\d+) distinct keywords? have (#{ACTIVITY}), observed by #{DATE}\./.match(text)
        return unless group
        searches = "#{group[1]} #{group[1] == '1' ? 'search' : 'searches'}"
        if group[2] == "preferred-page checks"
          reading("Check which pages Google is showing", "For #{searches}, a different page appeared from the one you chose.",
            "Open Keyword actions and compare the two pages for a search that matters to your business.", 60)
        else
          reading("Some rankings fell on consecutive days", "Review the starting positions for #{searches}.",
            "Open Keyword actions and check the ranking history for one of the affected searches.", 60)
        end
      end

      def ordinal(number)
        ActiveSupport::Inflector.ordinalize(number)
      end

      def reading(headline, meaning, action, priority)
        { headline: headline, meaning: meaning, action: action, priority: priority }
      end
    end
  end
end
