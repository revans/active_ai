require "net/http"

# Test-only double for Net::HTTP, used by the search adapter tests
# (test/tools/search_adapter/*_test.rb). The adapters build a raw
# Net::HTTP.new(...).request(...) call with no injectable client object, so
# faking the network means swapping Net::HTTP.new itself for the duration of
# a block — always restored in an ensure, never left patched between tests.
module NetHttpStub
  # response_class: a Net::HTTPResponse subclass, e.g. Net::HTTPOK, Net::HTTPUnauthorized.
  # on_request: optional callable invoked with the outgoing Net::HTTPGenericRequest,
  # for tests that need to inspect what was actually sent (e.g. an auth header).
  def stub_net_http_response(response_class:, body: nil, on_request: nil, &block)
    response = response_class.allocate
    response.instance_variable_set(:@body, body)
    response.instance_variable_set(:@read, true)

    with_fake_net_http(->(request) { on_request&.call(request); response }, &block)
  end

  # error: an exception instance to raise from Net::HTTP#request (e.g. Net::OpenTimeout.new)
  def stub_net_http_raise(error, &block)
    with_fake_net_http(->(_request) { raise error }, &block)
  end

  private

  def with_fake_net_http(request_impl)
    fake_http = Object.new
    fake_http.define_singleton_method(:use_ssl=)      { |_| }
    fake_http.define_singleton_method(:open_timeout=) { |_| }
    fake_http.define_singleton_method(:read_timeout=) { |_| }
    fake_http.define_singleton_method(:request, &request_impl)

    Net::HTTP.define_singleton_method(:new) { |*_args| fake_http }
    yield
  ensure
    Net::HTTP.singleton_class.send(:remove_method, :new)
  end
end
