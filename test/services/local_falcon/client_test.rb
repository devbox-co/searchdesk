require "test_helper"
require "active_support/testing/constant_stubbing"

class LocalFalconClientTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::ConstantStubbing

  test "streamable HTTP handles split events and closes upon receiving its own response" do
    received = []
    responder = Class.new(Net::HTTP) do
      define_singleton_method(:start) do |*_args, **_kwargs, &block|
        transport = Object.new
        transport.define_singleton_method(:request) do |req, &receive|
          payload = JSON.parse(req.body)
          received << [payload["method"], req["Authorization"], req["Mcp-Session-Id"], req["MCP-Protocol-Version"]]
          if payload["method"] == "notifications/initialized"
            ack = Net::HTTPAccepted.new("1.1", "202", "Accepted")
            ack.define_singleton_method(:read_body) { |_block = nil| nil }
            receive.call(ack)
            next ack
          end
          response = Net::HTTPOK.new("1.1", "200", "OK")
          response["Content-Type"] = "text/event-stream"
          response["Mcp-Session-Id"] = "test-session"
          output = if payload["method"] == "initialize"
            {protocolVersion: LocalFalcon::Client::VERSION}
          else
            {content: [{type: "text", text: JSON.generate({success: true, data: {locations: []}})}]}
          end
          frame = "event: message\r\ndata: #{JSON.generate({jsonrpc: '2.0', id: payload['id'], result: output})}\r\n\r\n"
          response.define_singleton_method(:read_body) do |&read|
            read.call(": keepalive\r\n\r\n")
            read.call(frame[0..12])
            read.call(frame[13..])
            raise "continued reading after matched MCP response"
          end
          receive.call(response)
          response
        end
        block.call(transport)
      end
    end
    stub_const(Net, :HTTP, responder) do
      client = LocalFalcon::Client.new.open_session("test-token")
      assert_equal({"locations"=>[]}, client.read("listAllLocalFalconLocations", {query: "place"}))
    end
    assert_equal ["initialize", "notifications/initialized", "tools/call"], received.map(&:first)
    assert_equal ["tools/call", "Bearer test-token", "test-session", LocalFalcon::Client::VERSION], received.last
  end
end
