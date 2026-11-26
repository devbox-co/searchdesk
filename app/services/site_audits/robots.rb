module SiteAudits
  class Robots
    PRODUCT = "searchdeskbot"
    class Unreadable < StandardError; end
    attr_reader :delay

    def initialize(content)
      groups = []
      agents = []
      directives = []
      content.to_s.b.force_encoding("UTF-8").scrub.delete_prefix("\uFEFF").each_line do |line|
        key, value = line.split("#", 2).first.to_s.split(":", 2).map(&:strip)
        next unless key && value
        if key.casecmp?("user-agent")
          if directives.any?
            groups << [agents, directives]
            agents, directives = [], []
          end
          agents << value.downcase
        elsif agents.any?
          directives << [key.downcase, value]
        end
      end
      groups << [agents, directives]
      chosen = groups.select { |names, _| names.include?(PRODUCT) }
      chosen = groups.select { |names, _| names.include?("*") } if chosen.empty?
      controls = chosen.flat_map(&:last)
      @delay = controls.filter_map { |key, value| Float(value, exception: false) if key == "crawl-delay" }.max.to_f
      raise Unreadable if controls.size > 8_192
      @rules = controls.filter_map do |key, value|
        next unless %w[allow disallow].include?(key) && value.start_with?("/")
        raise Unreadable if value.bytesize > 8192
        pattern = normalize(value)
        prefix = pattern.delete_suffix("$")
        expression = Regexp.escape(prefix).gsub("\\*", ".*")
        [prefix.delete("*").bytesize, key == "allow", Regexp.new("\\A#{expression}#{'\\z' if pattern.end_with?('$')}", timeout: 0.02)]
      end
    end

    def allowed?(path)
      candidate = normalize(path)
      winner = @rules.select { |_, _, regex| regex.match?(candidate) }.max_by { |size, allow, _| [size, allow ? 1 : 0] }
      !winner || winner[1]
    rescue Regexp::TimeoutError
      false
    end

    private

    def normalize(value)
      # RFC 9309 compares unreserved percent-encoded bytes as their ASCII equivalents.
      value.gsub(/%[0-9a-f]{2}|[^\x00-\x7F]/i) do |token|
        if token.start_with?("%")
          char = token[1..].to_i(16).chr
          char.match?(/[A-Za-z0-9._~-]/n) ? char : token.upcase
        else
          token.bytes.map { |byte| format("%%%02X", byte) }.join
        end
      end
    end
  end
end
