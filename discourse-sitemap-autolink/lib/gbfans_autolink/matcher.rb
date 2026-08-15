# frozen_string_literal: true

require "set"

module GbfansAutolink
  # Aho-Corasick multi-pattern matcher plus the deterministic match policy.
  #
  # Dependency-free on purpose: it can be exercised and benchmarked with
  # plain Ruby, outside a Discourse boot. One automaton scan finds every
  # candidate occurrence of every rule phrase in O(text length); the
  # policy layer then resolves overlaps (leftmost, then longest, then
  # priority) and applies the per-post frequency limits.
  #
  # Rules are plain hashes:
  #   { phrase: "elbow pads",           # already normalized (see .normalize)
  #     url: "/shop/grey-elbow-pads",   # destination (also the limit key)
  #     type: "product",
  #     priority: 1 }                   # lower wins ties
  class Matcher
    # Characters treated as word boundaries — the same set the
    # discourse-linkify-words theme component uses, so behavior stays
    # consistent during the migration.
    BOUNDARY_CHARS =
      [
        " ", "\t", "\n", "\r", " ",
        ":", ".", ";", ",", "!", "?", "…",
        "(", ")", "[", "]", "{", "}",
        "\"", "„", "“", "”", "«", "»",
      ].to_set

    def self.boundary?(char)
      char.nil? || BOUNDARY_CHARS.include?(char)
    end

    # Length-preserving normalization so match offsets in the normalized
    # string map 1:1 onto the original text node. Typographic apostrophes
    # fold to straight ones; NBSP folds to a space. If a rare Unicode
    # downcase changes the string length (e.g. "İ"), fall back to
    # per-character downcasing, keeping any character whose downcase is
    # not a single character.
    def self.normalize(text)
      folded = text.tr("’‘ ", "'' ")
      down = folded.downcase
      return down if down.length == folded.length

      folded.each_char.map { |c| (d = c.downcase).length == 1 ? d : c }.join
    end

    # Resolve candidates (tagged with node_index to preserve document
    # order across text nodes) into accepted matches, honoring:
    #   - leftmost match wins, then longest, then lowest priority number
    #   - a span claimed by a limit-capped winner is not re-awarded
    #   - counter: per-destination and total per-post limits
    def self.resolve(candidates, counter)
      sorted =
        candidates.sort_by do |c|
          [c[:node_index] || 0, c[:start], -c[:length], c[:rule][:priority] || 0]
        end
      accepted = []
      last_end = {}
      sorted.each do |candidate|
        node = candidate[:node_index] || 0
        next if candidate[:start] < (last_end[node] || 0)
        last_end[node] = candidate[:start] + candidate[:length]
        next unless counter.allows?(candidate[:rule][:url])
        counter.record(candidate[:rule][:url])
        accepted << candidate
      end
      accepted
    end

    attr_reader :rules

    def initialize(rules)
      @rules = rules
      build_automaton
    end

    def size
      @rules.size
    end

    # Scan normalized text; returns every rule occurrence that sits on
    # word boundaries as { start:, length:, rule: } (in characters).
    def scan(text)
      chars = text.chars
      candidates = []
      state = 0
      chars.each_with_index do |ch, i|
        state = @fail[state] until state.zero? || @goto[state].key?(ch)
        state = @goto[state][ch] || 0
        @out[state].each do |rule_index|
          rule = @rules[rule_index]
          length = rule[:phrase].length
          start = i - length + 1
          next unless self.class.boundary?(start.zero? ? nil : chars[start - 1])
          next unless self.class.boundary?(chars[i + 1])
          candidates << { start: start, length: length, rule: rule }
        end
      end
      candidates
    end

    private

    def build_automaton
      @goto = [{}]
      @fail = [0]
      @out = [[]]

      @rules.each_with_index do |rule, index|
        state = 0
        rule[:phrase].each_char do |ch|
          state =
            @goto[state][ch] ||= begin
              @goto << {}
              @fail << 0
              @out << []
              @goto.size - 1
            end
        end
        @out[state] << index
      end

      queue = []
      @goto[0].each_value do |s|
        @fail[s] = 0
        queue << s
      end
      until queue.empty?
        r = queue.shift
        @goto[r].each do |ch, s|
          queue << s
          f = @fail[r]
          f = @fail[f] until f.zero? || @goto[f].key?(ch)
          target = @goto[f][ch]
          @fail[s] = target && target != s ? target : 0
          @out[s] |= @out[@fail[s]]
        end
      end
    end
  end

  # Per-post link budget: per-destination and total limits, 0 = unlimited.
  class LinkCounter
    attr_reader :total

    def initialize(max_per_destination:, max_total:)
      @max_per_destination = max_per_destination
      @max_total = max_total
      @per_destination = Hash.new(0)
      @total = 0
    end

    def allows?(destination)
      return false if @max_total.positive? && @total >= @max_total
      if @max_per_destination.positive? &&
           @per_destination[destination] >= @max_per_destination
        return false
      end
      true
    end

    def record(destination)
      @per_destination[destination] += 1
      @total += 1
    end
  end
end
