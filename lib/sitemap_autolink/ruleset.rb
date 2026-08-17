# frozen_string_literal: true

module SitemapAutolink
  # An immutable compiled set of linking rules plus its lazily built
  # matcher. Rule phrases must already be normalized (Matcher.normalize)
  # and deduplicated — one rule per phrase, collisions already resolved.
  class Ruleset
    # Rule URLs are written verbatim into cooked post HTML, which is
    # served to every reader — so only plainly safe shapes may compile:
    # absolute http(s) URLs (the only kind a sitemap may contain) and
    # single-slash forum-relative paths (manual mappings). Everything
    # else — javascript:, data:, vbscript:, protocol-relative //host —
    # is dropped here, at the one choke point every rule source shares,
    # so a compromised sitemap can never inject an executable href.
    #
    # The lookahead rejects a backslash as well as a slash: the URL spec
    # normalizes \ to /, so "/\evil.example" is the protocol-relative
    # "//evil.example" spelled differently and leaves the forum origin.
    SAFE_URL = %r{\A(?:https?://|/(?![/\\]))}i

    # Browsers DELETE tab, LF and CR from a URL before parsing it, so
    # "/<tab>/evil.example" is another spelling of "//evil.example".
    # Deleting what the browser deletes before matching is what keeps
    # the pattern above from being a guard the browser disagrees with.
    BROWSER_STRIPPED = /[\t\n\r]/

    def self.safe_url?(url)
      SAFE_URL.match?(url.to_s.gsub(BROWSER_STRIPPED, ""))
    end

    attr_reader :rules, :version

    def initialize(rules, version: 0)
      @rules = rules.freeze
      @version = version
    end

    def empty?
      @rules.empty?
    end

    def size
      @rules.size
    end

    def matcher
      @matcher ||= Matcher.new(@rules)
    end

    # Deterministic collision resolution shared by every rule source:
    # among rules with the same normalized phrase keep the one with the
    # lowest priority number; tie-break on URL for stable builds.
    def self.compile(raw_rules, version: 0)
      winners = {}
      raw_rules.each do |rule|
        phrase = rule[:phrase]
        next if phrase.nil? || phrase.empty?
        next if !safe_url?(rule[:url])
        current = winners[phrase]
        winners[phrase] = rule if current.nil? || better?(rule, current)
      end
      new(winners.values.sort_by { |r| [r[:priority] || 0, r[:phrase]] }, version: version)
    end

    def self.better?(a, b)
      ([a[:priority] || 0, a[:url].to_s] <=> [b[:priority] || 0, b[:url].to_s]) < 0
    end
  end
end
