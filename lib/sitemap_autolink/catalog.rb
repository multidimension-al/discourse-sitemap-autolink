# frozen_string_literal: true

module SitemapAutolink
  # Builds and caches the compiled ruleset the linking hook consumes.
  #
  # The ruleset is memoized per process and keyed by (redis catalog
  # version) + (relevant site setting values), so:
  #   - any entry/term mutation bumps the redis version -> every process
  #     recompiles lazily on its next post-process;
  #   - setting changes recompile without needing a version bump;
  #   - post cooking NEVER touches the sitemap or the network.
  module Catalog
    VERSION_KEY = "sitemap_autolink_catalog_version"

    def self.version
      Discourse.redis.get(VERSION_KEY).to_i
    end

    def self.bump_version!
      Discourse.redis.incr(VERSION_KEY)
    end

    def self.linkable_post?(post)
      return false if post.blank? || post.raw.blank?
      return false if post.post_type != Post.types[:regular]
      if !SiteSetting.sitemap_autolink_include_private_messages
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
      excluded = SiteSetting.sitemap_autolink_excluded_categories.split("|").map(&:to_i)
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
      list = SiteSetting.sitemap_autolink_type_priority.split("|")
      list.index(type.to_s) || list.size
    end

    def self.ruleset
      v = version
      settings_fingerprint =
        [
          SiteSetting.sitemap_autolink_manual_mappings,
          SiteSetting.sitemap_autolink_enabled_types,
          SiteSetting.sitemap_autolink_type_priority,
          SiteSetting.sitemap_autolink_excluded_terms,
          SiteSetting.sitemap_autolink_excluded_url_patterns,
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
      rules = manual_mapping_rules + database_rules
      Ruleset.compile(rules, version: version)
    end

    # "phrase,url,type" entries in a site setting. They rank as manual
    # overrides and need no catalog rows. Relative URLs resolve against
    # the forum origin.
    def self.manual_mapping_rules
      SiteSetting
        .sitemap_autolink_manual_mappings
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
      return [] unless SitemapAutolinkEntry.table_exists?

      enabled_types = SiteSetting.sitemap_autolink_enabled_types.split("|")
      excluded =
        SiteSetting
          .sitemap_autolink_excluded_terms
          .split("|")
          .map { |t| Matcher.normalize(t) }
          .to_set
      url_filter =
        UrlFilter.compile(SiteSetting.sitemap_autolink_excluded_url_patterns.split("|"))

      scope =
        SitemapAutolinkTerm
          .linkable
          .joins(:entry)
          .merge(SitemapAutolinkEntry.active)
      # An empty enabled_types list means every configured type may link.
      if enabled_types.present?
        scope = scope.where(sitemap_autolink_entries: { content_type: enabled_types })
      end

      scope
        .pluck(
          "sitemap_autolink_terms.normalized_phrase",
          "sitemap_autolink_terms.origin",
          "sitemap_autolink_entries.id",
          "sitemap_autolink_entries.url",
          "sitemap_autolink_entries.content_type",
          "sitemap_autolink_entries.priority",
        )
        .filter_map do |phrase, origin, entry_id, url, content_type, priority|
          manual = SitemapAutolinkTerm.manual_origin?(origin)
          # The excluded-terms gate protects against generated noise; an
          # explicit manual alias is an admin decision and passes.
          next if !manual && excluded.include?(phrase)
          # URL patterns take effect immediately, even for entries
          # ingested before the pattern was added.
          next if UrlFilter.excluded?(url, url_filter)
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
