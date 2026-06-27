require "net/http"
require "ipaddr"

module ActiveAI
  module Tools
    # Fetches a URL and returns its text content with HTML stripped.
    # No API key required — uses Ruby's stdlib Net::HTTP.
    # Think of it as "curl + strip tags": you give it a URL, it gives you the words.
    class WebPageReader < ActiveAI::Tool::Base
      MAX_CHARS = 8_000
      MAX_BYTES = 2_097_152  # 2 MB hard cap before HTML stripping

      ALLOWED_SCHEMES = %w[http https].freeze
      ALLOWED_PORTS   = [80, 443].freeze

      # Blocks loopback, RFC 1918 private, link-local (cloud metadata endpoints),
      # CGNAT, reserved, multicast, and their IPv6 equivalents.
      BLOCKED_RANGES = [
        IPAddr.new("127.0.0.0/8"),    # loopback
        IPAddr.new("10.0.0.0/8"),     # RFC 1918 private
        IPAddr.new("172.16.0.0/12"),  # RFC 1918 private
        IPAddr.new("192.168.0.0/16"), # RFC 1918 private
        IPAddr.new("169.254.0.0/16"), # link-local / cloud metadata (AWS, GCP, Azure)
        IPAddr.new("100.64.0.0/10"),  # CGNAT (RFC 6598)
        IPAddr.new("192.0.0.0/24"),   # IETF protocol assignments
        IPAddr.new("0.0.0.0/8"),      # "this" network
        IPAddr.new("224.0.0.0/4"),    # multicast
        IPAddr.new("240.0.0.0/4"),    # reserved
        IPAddr.new("::1/128"),        # IPv6 loopback
        IPAddr.new("fc00::/7"),       # IPv6 ULA (private)
        IPAddr.new("fe80::/10"),      # IPv6 link-local
        IPAddr.new("ff00::/8"),       # IPv6 multicast
      ].freeze

      tool_name "read_webpage"
      description "Fetch and read the text content of a webpage. Use this after a web search to read a specific page in full."

      param :url, type: :string, description: "The full URL of the webpage to read"

      def call(url:)
        body = fetch(url)
        strip_html(body).truncate(MAX_CHARS)
      rescue => e
        "Error reading #{url}: #{e.message}"
      end

      private

      def fetch(url, redirects_remaining = 5)
        raise "Too many redirects" if redirects_remaining.zero?

        uri = URI.parse(url)
        validate_uri!(uri)

        resolved_ip  = validate_uri!(uri)
        redirect_url = nil
        body         = nil

        # Connect to the pre-validated IP directly (ipaddr=) so DNS cannot be
        # re-resolved between validation and connection (TOCTOU / DNS rebinding).
        # uri.host is still used for TLS SNI and the Host header.
        http = Net::HTTP.new(uri.host, uri.port)
        http.ipaddr       = resolved_ip
        http.use_ssl      = uri.scheme == "https"
        http.open_timeout = 5
        http.read_timeout = 15

        http.start do |h|
          req = Net::HTTP::Get.new(uri)
          req["User-Agent"] = "ActiveAI/#{ActiveAI::VERSION}"

          h.request(req) do |response|
            case response
            when Net::HTTPRedirection
              # Resolve relative locations; validate_uri! runs on next recursion.
              redirect_url = URI.join(uri, response["location"]).to_s
            when Net::HTTPSuccess
              content_length = response["content-length"]&.to_i
              raise "Response too large" if content_length && content_length > MAX_BYTES

              body = +""
              response.read_body do |chunk|
                body << chunk
                raise "Response too large (>#{MAX_BYTES / 1_048_576}MB)" if body.bytesize > MAX_BYTES
              end
            else
              raise "HTTP #{response.code}"
            end
          end
        end

        redirect_url ? fetch(redirect_url, redirects_remaining - 1) : body
      end

      # Returns the resolved IP string to use for the connection.
      # Validates scheme, port, and all resolved IPs before returning.
      def validate_uri!(uri)
        raise "Blocked scheme: #{uri.scheme.inspect}" unless ALLOWED_SCHEMES.include?(uri.scheme)
        raise "Non-standard port: #{uri.port}" unless ALLOWED_PORTS.include?(uri.port)

        ips = Addrinfo.getaddrinfo(uri.host, nil, nil, :STREAM).map(&:ip_address).uniq
        ips.each do |ip_str|
          ip = IPAddr.new(ip_str)
          if BLOCKED_RANGES.any? { |range| range.include?(ip) }
            raise "Blocked: #{uri.host} resolves to a private or reserved address"
          end
        end
        ips.first
      rescue SocketError
        raise "Could not resolve host: #{uri.host}"
      end

      def strip_html(html)
        html
          .gsub(/<!--.*?-->/m, "")
          .gsub(/<script[^>]*>.*?<\/script>/mi, "")
          .gsub(/<style[^>]*>.*?<\/style>/mi, "")
          .gsub(/<[^>]+>/, " ")
          .gsub(/&nbsp;/, " ").gsub(/&amp;/, "&").gsub(/&lt;/, "<").gsub(/&gt;/, ">").gsub(/&quot;/, '"')
          .gsub(/\s+/, " ")
          .strip
      end
    end
  end
end
