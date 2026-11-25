require "test_helper"

class SiteAuditsFetcherTest < ActiveSupport::TestCase
  class TransportSpy
    attr_accessor :ipaddr, :use_ssl, :verify_mode, :open_timeout, :read_timeout, :max_retries
    attr_reader :args, :response_completed, :request_seen
    alias_method :use_ssl?, :use_ssl

    def initialize(response)
      @response = response
    end

    def new(*args)
      @args = args
      self
    end

    def request(message)
      @request_seen = message
      yield @response
      @response_completed = true
    end
  end

  def fetcher(ips:, status: 302, type: "text/html")
    resolver = Object.new
    resolver.define_singleton_method(:getaddrinfo) { |*| ips.map { |ip| Addrinfo.ip(ip) } }
    response = Net::HTTPResponse.new("1.1", status.to_s, "Fixture")
    response["Content-Type"] = type
    response.define_singleton_method(:read_body) { raise "Skipped body was read" }
    @http = TransportSpy.new(response)
    SiteAudits::Fetcher.new(resolver: resolver, transport: @http)
  end

  test "a response outside the HTML checks terminates before the transport can drain its body" do
    result = fetcher(ips: ["8.8.8.8"], status: 200, type: "application/pdf").get(URI("https://example.test/catalogue"))
    assert_equal ["example.test", 443, nil], @http.args
    assert_equal "8.8.8.8", @http.ipaddr
    assert_equal OpenSSL::SSL::VERIFY_PEER, @http.verify_mode
    assert_equal "identity", @http.request_seen["accept-encoding"]
    assert_equal "/catalogue", @http.request_seen.path
    assert_equal "", result.body
    assert_nil @http.response_completed
  end

  test "mixed DNS answers reject the entire request before opening a socket" do
    adapter = fetcher(ips: ["8.8.8.8", "127.0.0.1"])
    assert_raises(SiteAudits::Fetcher::Error) { adapter.get(URI("https://example.test/")) }
    assert_nil @http.args
  end
end
