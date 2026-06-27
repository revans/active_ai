require "net/http"
require "json"

module ActiveAI
  module Tools
    module SearchAdapter
      class Tavily < Base
        ENV_KEY = "TAVILY_API_KEY"

        def search(query)
          require_api_key!
          results = call_api(query)
          format_results(results)
        end

        private

        def call_api(query)
          uri  = URI("https://api.tavily.com/search")
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl      = true
          http.open_timeout = 5
          http.read_timeout = 15

          request = Net::HTTP::Post.new(uri)
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(api_key: api_key, query: query, search_depth: "basic", max_results: 5)

          response = http.request(request)
          return [] unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body).fetch("results", []).map do |search_result|
            { title: search_result["title"], url: search_result["url"], body: search_result["content"].to_s }
          end
        rescue => api_error
          Rails.logger.error("ActiveAI::Tools::SearchAdapter::Tavily error: #{api_error.message}")
          []
        end
      end
    end
  end
end
