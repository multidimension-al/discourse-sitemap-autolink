# frozen_string_literal: true

# Standalone dry run of the ingestion pipeline — plain Ruby, no
# Discourse, nothing written anywhere. Fetches real sitemaps, resolves
# real titles, generates the phrases the plugin would link, and prints
# everything. Use it to see exactly what the plugin would do before
# installing anything.
#
#   ruby script/preview_sync.rb \
#     --source "https://example.com/sitemap-products.xml,product" \
#     --source "https://example.com/sitemap-wiki.xml,wiki" \
#     [--limit 10] [--suffix " - Example Shop"] [--exclude "*/tag/*"] \
#     [--user-agent "Mozilla/5.0 ..."]

require "optparse"
require "set"
require_relative "../lib/sitemap_autolink/matcher"
require_relative "../lib/sitemap_autolink/term_generator"
require_relative "../lib/sitemap_autolink/url_filter"

# Outside Rails there is no ActiveSupport; provide the few core
# extensions the library uses.
unless Object.method_defined?(:blank?)
  class Object
    def blank?
      respond_to?(:empty?) ? !!empty? : !self
    end

    def present?
      !blank?
    end

    def presence
      present? ? self : nil
    end
  end

  class String
    def blank?
      strip.empty?
    end
  end
end

# SitemapSync's DB-facing methods are unused in preview mode, but the
# class references the entry model for URL normalization; provide the
# minimal stand-in so the file loads outside Rails.
unless defined?(SitemapAutolinkEntry)
  class SitemapAutolinkEntry
    def self.normalize_url(url)
      url.to_s.strip.sub(%r{/+\z}, "")
    end
  end
end

require_relative "../lib/sitemap_autolink/sitemap_sync"

sources = []
suffixes = []
excludes = []
limit = 10
user_agent = nil
plurals = true

OptionParser.new do |opts|
  opts.on("--source SRC", "sitemap URL,content_type (repeatable)") do |v|
    url, type = v.split(",").map(&:strip)
    sources << { url: url, type: type || "content" }
  end
  opts.on("--suffix SUFFIX", "title suffix to strip (repeatable)") { |v| suffixes << v }
  opts.on("--exclude PATTERN", "URL exclusion pattern (repeatable)") { |v| excludes << v }
  opts.on("--limit N", Integer, "pages sampled per source (default 10)") { |v| limit = v }
  opts.on("--user-agent UA", "override the HTTP user agent") { |v| user_agent = v }
  opts.on("--no-plurals", "do not generate plural phrase variants") { plurals = false }
end.parse!

abort("at least one --source is required") if sources.empty?

sync =
  SitemapAutolink::SitemapSync.new(
    sources: sources,
    title_suffixes: suffixes,
    excluded_url_patterns: excludes,
    user_agent: user_agent,
  )

term_settings = {
  min_phrase_length: 5,
  min_phrase_words: 2,
  generate_plurals: plurals,
  excluded_terms: Set.new,
}

started = Time.now
result = sync.preview(limit_per_source: limit, term_settings: term_settings)
elapsed = Time.now - started

result[:errors].each { |e| puts "ERROR: #{e}" }
result[:sources].each do |source|
  puts "\n=== #{source[:sitemap]} (type: #{source[:type]})"
  puts "    URLs in sitemap: #{source[:total_urls]}   excluded by pattern: #{source[:excluded_by_pattern]}"
  source[:excluded_sample].each { |u| puts "    excluded: #{u}" }
  source[:sampled].each do |page|
    puts "  #{page[:url]}"
    puts "      title (#{page[:title_source]}): #{page[:title]}"
    page[:phrases].each do |p|
      note = p[:state] == "auto_active" ? "ACTIVE" : "review needed: #{p[:reason]}"
      puts "      would link \"#{p[:phrase]}\"  [#{note}]"
    end
  end
end
puts format("\ndone in %.1fs — nothing was written; this is a dry run.", elapsed)
