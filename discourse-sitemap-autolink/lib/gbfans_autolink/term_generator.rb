# frozen_string_literal: true

module GbfansAutolink
  # Generates candidate matching phrases from a canonical title, with
  # conservative variants and safety gating. Semantic aliases ("elbow
  # pads" for "Grey Elbow Pads") are deliberately NOT invented here —
  # those are manual, admin-approved decisions.
  #
  # Returns [{ phrase:, state:, reason: }] where state is :auto_active or
  # :pending_review. Phrases gated by the global excluded-terms list are
  # not returned at all.
  module TermGenerator
    COMMON_SINGLE_WORDS =
      %w[
        pack packs belt belts patch patches uniform uniforms suit suits glove
        gloves boot boots shirt shirts hat hats pin pins kit kits set sets
        tube tubing hose hoses wire wires label labels sticker stickers strap
        straps clip clips light lights sound sounds board boards frame frames
        pad pads foam metal plastic resin rubber leather ghost ghosts slime
        slimer trap traps wand wands gun guns box boxes bag bags case cases
        cover covers grip grips handle handles mount mounts screw screws
        spring springs magnet magnets battery batteries speaker speakers red
        blue green grey gray black white yellow orange brown purple pink gold
        silver brass copper chrome clear custom official vintage classic
        original special limited standard basic complete full half quarter
        mini micro mega super ultra pro plus deluxe premium guide guides news
        blog page pages home shop store wiki forum gallery video videos photo
        photos image images music song songs episode episodes season seasons
        character characters people person crew cast story stories history
        location locations vehicle vehicles equipment gear bank banks tank
        tanks barrel barrels bottle bottles glass glasses poster posters
        banner banners button buttons badge badges keychain comic comics
        game games movie movies film films book books toy toys card cards
        sign signs mug mugs cap caps
      ].to_set

    def self.generate(title, content_type, settings = default_settings)
      variants = build_variants(title, content_type)
      excluded = settings[:excluded_terms]
      seen = {}
      variants.filter_map do |raw|
        phrase = Matcher.normalize(raw)
        next if phrase.empty? || seen[phrase]
        seen[phrase] = true
        next if excluded.include?(phrase)
        gate(raw, phrase, content_type, settings)
      end
    end

    def self.gate(raw, phrase, content_type, settings)
      words = phrase.split(" ")
      if phrase.length < settings[:min_phrase_length]
        return { phrase: raw, state: :pending_review, reason: "too_short" }
      end
      if words.size == 1 && COMMON_SINGLE_WORDS.include?(singular(phrase))
        return { phrase: raw, state: :pending_review, reason: "generic_word" }
      end
      if content_type == "wiki" && words.size < settings[:min_wiki_words] &&
           !letter_digit_token?(phrase)
        return { phrase: raw, state: :pending_review, reason: "single_word_wiki" }
      end
      { phrase: raw, state: :auto_active, reason: nil }
    end

    def self.build_variants(title, content_type)
      base = title.to_s.gsub(/\s+/, " ").strip
      return [] if base.empty?
      variants = [base]

      # Shop line prefixes: "Pack: ALICE Frame Padding"
      if %w[product category].include?(content_type) &&
           (m = base.match(/\A([^:]{2,24}):\s+(.+)\z/))
        variants << m[2]
      end

      # Trailing parentheticals: "Clippard Brass Elbow (GB1 Ion Arm)"
      variants
        .dup
        .each do |v|
          variants << Regexp.last_match(1) if v =~ /\A(.*\S)\s*\([^)]*\)\z/
        end

      # Leading article for wiki-style titles
      variants
        .dup
        .each { |v| variants << v.sub(/\Athe\s+/i, "") if v =~ /\Athe\s+/i }

      # Conservative plural/singular — only on clean variants; pluralizing
      # a "Line: Name" or "(…)" form just makes noise.
      variants
        .dup
        .each do |v|
          next if v.include?(":") || v.include?("(")
          if !v.match?(/s\z/i)
            variants << "#{v}s" if %w[product category].include?(content_type)
          elsif v.length > 5 && !v.match?(/(ss|us|is)\z/i)
            variants << v[0..-2]
          end
        end

      # "&" <-> "and"
      variants
        .dup
        .each do |v|
          if v.include?(" & ")
            variants << v.gsub(" & ", " and ")
          elsif v.match?(/\sand\s/)
            variants << v.gsub(/\sand\s/, " & ")
          end
        end

      variants
    end

    def self.singular(word)
      if word.length >= 5 && word.end_with?("s") && !word.match?(/(ss|us|is)\z/)
        stripped = word[0..-2]
        return stripped if COMMON_SINGLE_WORDS.include?(stripped)
      end
      word
    end

    def self.letter_digit_token?(phrase)
      phrase.match?(/[a-z]/i) && phrase.match?(/\d/)
    end

    def self.default_settings
      if defined?(SiteSetting)
        {
          min_phrase_length: SiteSetting.gbfans_autolink_min_phrase_length,
          min_wiki_words: SiteSetting.gbfans_autolink_min_wiki_words,
          excluded_terms:
            SiteSetting
              .gbfans_autolink_excluded_terms
              .split("|")
              .map { |t| Matcher.normalize(t) }
              .to_set,
        }
      else
        { min_phrase_length: 5, min_wiki_words: 2, excluded_terms: Set.new }
      end
    end
  end
end
