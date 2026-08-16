# frozen_string_literal: true

module SitemapAutolink
  # URL exclusion patterns for sitemap ingestion and matching.
  #
  # A pattern is matched case-insensitively against the full URL:
  #   - containing "*"  -> wildcard match ("*" spans any characters),
  #     e.g. "*/checkout*", "https://example.com/tag/*"
  #   - otherwise       -> plain substring match, e.g. "/uncategorized/"
  module UrlFilter
    def self.compile(patterns)
      patterns.filter_map do |pattern|
        pattern = pattern.to_s.strip
        next if pattern.empty?
        if pattern.include?("*")
          Regexp.new(
            pattern.split("*", -1).map { |part| Regexp.escape(part) }.join(".*"),
            Regexp::IGNORECASE,
          )
        else
          Regexp.new(Regexp.escape(pattern), Regexp::IGNORECASE)
        end
      end
    end

    def self.excluded?(url, compiled_patterns)
      compiled_patterns.any? { |regexp| regexp.match?(url) }
    end
  end
end
