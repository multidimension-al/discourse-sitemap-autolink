# frozen_string_literal: true

module GbfansAutolink
  # Builds and caches the compiled ruleset the linking hook consumes.
  #
  # The ruleset is memoized per process and keyed by (redis catalog
  # version) + (relevant site setting values), so:
  #   - any entry/term mutation bumps the redis version -> every process
  #     recompiles lazily on its next post-process;
  #   - setting changes recompile without needing a version bump;
  #   - post cooking NEVER touches the sitemap or the network.
  module Catalog
    VERSION_KEY = "gbfans_autolink_catalog_version"

    def self.version
      Discourse.redis.get(VERSION_KEY).to_i
    end

    def self.bump_version!
      Discourse.redis.incr(VERSION_KEY)
    end

    def self.linkable_post?(post)
      return false if post.blank? || post.raw.blank?
      return false if post.post_type != Post.types[:regular]
      if !SiteSetting.gbfans_autolink_include_private_messages
        return false if post.topic.nil? || post.topic.private_message?
      end
      return false if excluded_category?(post.topic&.category_id)
      true
    end

    # True when the post's category — or any ancestor of it — is in the
    # excluded list (e.g. marketplace/for-sale areas, where members'
    # own listings must not gain shop links).
    def self.excluded_category?(category_id)
      return false if category_id.blank?
      excluded = SiteSetting.gbfans_autolink_excluded_categories.split("|").map(&:to_i)
      return false if excluded.empty?
      current = category_id
      depth = 0
      while current.present? && depth < 5
        return true if excluded.include?(current)
        current = Category.where(id: current).pick(:parent_category_id)
        depth += 1
      end
      false
    end

    def self.type_rank(type)
      list = SiteSetting.gbfans_autolink_type_priority.split("|")
      list.index(type.to_s) || list.size
    end

    def self.ruleset
      v = version
      settings_fingerprint =
        [
          SiteSetting.gbfans_autolink_test_mappings,
          SiteSetting.gbfans_autolink_enabled_types,
          SiteSetting.gbfans_autolink_type_priority,
          SiteSetting.gbfans_autolink_excluded_terms,
        ].hash
      if @ruleset.nil? || @cached_version != v || @cached_settings != settings_fingerprint
        @ruleset = build_ruleset(v)
        @cached_version = v
        @cached_settings = settings_fingerprint
      end
      @ruleset
    end

    def self.reset_cache!
      @ruleset = nil
    end

    def self.build_ruleset(version)
      rules = test_mapping_rules + database_rules
      Ruleset.compile(rules, version: version)
    end

    # PoC / migration convenience: "phrase,url,type" entries in a site
    # setting. They rank as manual and need no catalog rows.
    def self.test_mapping_rules
      SiteSetting
        .gbfans_autolink_test_mappings
        .split("|")
        .filter_map do |row|
          phrase, url, type = row.split(",").map(&:strip)
          next if phrase.blank? || url.blank?
          {
            phrase: Matcher.normalize(phrase),
            url: url,
            type: type.presence || "manual",
            priority: type_rank("manual"),
          }
        end
    end

    def self.database_rules
      return [] unless GbfansAutolinkEntry.table_exists?

      enabled_types = SiteSetting.gbfans_autolink_enabled_types.split("|")
      excluded =
        SiteSetting
          .gbfans_autolink_excluded_terms
          .split("|")
          .map { |t| Matcher.normalize(t) }
          .to_set

      GbfansAutolinkTerm
        .linkable
        .joins(:entry)
        .merge(GbfansAutolinkEntry.active)
        .where(gbfans_autolink_entries: { content_type: enabled_types })
        .pluck(
          "gbfans_autolink_terms.normalized_phrase",
          "gbfans_autolink_terms.origin",
          "gbfans_autolink_entries.id",
          "gbfans_autolink_entries.url",
          "gbfans_autolink_entries.content_type",
          "gbfans_autolink_entries.priority",
        )
        .filter_map do |phrase, origin, entry_id, url, content_type, priority|
          manual = origin == GbfansAutolinkTerm.origins[:manual]
          # The excluded-terms gate protects against generated noise; an
          # explicit manual alias is an admin decision and passes.
          next if !manual && excluded.include?(phrase)
          {
            phrase: phrase,
            url: url,
            type: content_type,
            priority: priority || type_rank(manual ? "manual" : content_type),
            entry_id: entry_id,
          }
        end
    rescue ActiveRecord::StatementInvalid
      # Table not migrated yet — run with settings-based rules only.
      []
    end
  end
end
