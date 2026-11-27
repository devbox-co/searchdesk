require "nokogiri"

module SiteAudits
  module PublicPageReader
    include CrawlRequests

    MAX_REDIRECTS = 3
    Page = Data.define(:uri, :visited, :response)

    private

    def read_public_page(uri, label)
      visited = Set.new
      loop do
        raise Stop, "The #{label} page has too many redirects or redirects in a loop." if visited.size > MAX_REDIRECTS || !visited.add?(uri.to_s)
        raise Stop, "The site's crawl rules prevent checking the #{label} page." unless policy_for(uri).allowed?(uri.path)
        response = fetch(uri)
        unless REDIRECTS.include?(response.status)
          return Page.new(uri, visited, response)
        end
        destination = @scope.resolve(response.location, base: uri)
        raise Stop, "The #{label} page redirects outside the public pages this check can read." unless destination
        yield(uri, response.status, destination) if block_given?
        uri = destination
      end
    end

    def readable_html(page, label)
      response = page.response
      raise Stop, "The #{label} page returned HTTP #{response.status}." unless response.status == 200
      raise Stop, "The #{label} page did not return HTML." unless Crawler::HTML.include?(response.content_type)
      document = if response.content_type == "application/xhtml+xml"
        Nokogiri::XML(response.body) { |options| options.strict.nonet }.remove_namespaces!
      else
        body = response.body
        encoding = if body.encoding != Encoding::BINARY
          body.encoding.name
        else
          declared = Nokogiri::HTML4::EncodingReader.detect_encoding(body.byteslice(0, 4096))
          declared || ("UTF-8" if body.dup.force_encoding("UTF-8").valid_encoding?)
        end
        Nokogiri::HTML4(body, nil, encoding)
      end
      if document.at_css("title")&.text.to_s.match?(/\A\s*(just a moment|access denied|request rejected|verify (you are|you're) human|checking your browser)\b/i) || document.at_css("#challenge-form")
        raise Stop, "The #{label} page returned a verification screen."
      end
      yield document if block_given?
      document.css("script, style, template, noscript, [hidden], [inert], [aria-hidden='true']").remove
      document.css("[style]").each do |node|
        node.remove if node["style"].match?(/(?:\A|;)\s*(?:display\s*:\s*none|visibility\s*:\s*hidden)\s*(?:!important\s*)?(?:;|\z)/i)
      end
      body_text = document.at_css("body")&.text.to_s.squish
      if body_text.blank? || body_text.match?(/\A(?:loading|please wait|enable javascript|please enable javascript)\b.{0,80}\z/i)
        raise Stop, "The #{label} page supplied no readable content."
      end
      document
    end
  end
end
