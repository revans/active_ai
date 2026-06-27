require "net/http"
require "json"

module ActiveAI
  module Tools
    module SearchAdapter
      class Brave < Base
        ENV_KEY = "BRAVE_API_KEY"

        def search(query)
          require_api_key!
          results = call_api(query)
          format_results(results)
        end

        private

        def call_api(query)
          uri       = URI("https://api.search.brave.com/res/v1/web/search")
          uri.query = URI.encode_www_form(q: query, count: 5)

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl      = true
          http.open_timeout = 5
          http.read_timeout = 15

          request = Net::HTTP::Get.new(uri)
          request["Accept"]               = "application/json"
          request["X-Subscription-Token"] = api_key

          response = http.request(request)
          return [] unless response.is_a?(Net::HTTPSuccess)

          (JSON.parse(response.body).dig("web", "results") || []).map do |search_result|
            { title: search_result["title"], url: search_result["url"], body: search_result["description"].to_s }
          end
        rescue => api_error
          Rails.logger.error("ActiveAI::Tools::SearchAdapter::Brave error: #{api_error.message}")
          []
        end
      end
    end
  end
end
