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
    SAFE_URL = %r{\A(?:https?://|/(?!/))}i

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
        next if !SAFE_URL.match?(rule[:url].to_s)
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
