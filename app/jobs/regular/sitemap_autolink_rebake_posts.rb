# frozen_string_literal: true

module Jobs
  # Rebakes posts that likely contain ANY of the given phrases, as one
  # self-continuing job for the whole batch (modeled on core's
  # Jobs::RebakeCustomEmojiPosts). A single deduplicated ILIKE ANY scan
  # means a post matching five changed phrases is rebaked once, not five
  # times; sitemap_autolink_max_rebakes_per_job_run bounds each run, and
  # max_posts caps the whole wave so a catalog-wide change can never
  # queue an unbounded rebake. raw ILIKE is only a candidate filter —
  # the cook-time matcher decides whether a link actually appears.
  class SitemapAutolinkRebakePosts < ::Jobs::Base
    sidekiq_options queue: "low"

    MAX_PHRASES = 1000
    # all_phrases mode derives the list from the catalog at run time
    # instead of carrying it in the job payload, so it gets a higher cap.
    MAX_ALL_PHRASES = 10_000

    def execute(args)
      all_phrases = !!args[:all_phrases]
      limit = all_phrases ? MAX_ALL_PHRASES : MAX_PHRASES
      phrases =
        (all_phrases ? active_catalog_phrases : Array(args[:phrases]))
          .map { |p| p.to_s.strip }
          .reject { |p| p.length < 3 }
          .uniq
      if phrases.size > limit
        Rails.logger.warn(
          "sitemap-autolink rebake: phrase list truncated from #{phrases.size} to #{limit}",
        )
        phrases = phrases.first(limit)
      end
      return if phrases.empty?

      # 0 = no wave cap (admin-triggered single-phrase rebakes).
      max_posts = args[:max_posts].to_i
      budget = SiteSetting.sitemap_autolink_max_rebakes_per_job_run
      budget = [budget, max_posts].min if max_posts.positive?
      return if budget <= 0

      after_id = args[:after_id].to_i
      patterns =
        phrases
          .flat_map { |p| raw_spellings(p) }
          .uniq
          .map { |p| "%#{ActiveRecord::Base.sanitize_sql_like(p)}%" }

      batch =
        Post
          .where(deleted_at: nil)
          .where("posts.id > ?", after_id)
          .where("posts.raw ILIKE ANY (ARRAY[?])", patterns)
          .order(:id)
          .limit(budget)
          .to_a

      batch.each do |post|
        begin
          post.rebake!(priority: :low)
        rescue => e
          Rails.logger.warn("sitemap-autolink rebake failed for post #{post.id}: #{e.message}")
        end
      end

      return if batch.size < budget

      if max_posts.positive?
        remaining = max_posts - batch.size
        if remaining <= 0
          Rails.logger.warn(
            "sitemap-autolink rebake: wave stopped at its " \
              "sitemap_autolink_auto_rebake_max_posts cap; posts beyond id " \
              "#{batch.last.id} pick up link changes when next edited or rebaked",
          )
          return
        end
      else
        remaining = 0
      end

      followup = { after_id: batch.last.id, max_posts: remaining }
      if all_phrases
        followup[:all_phrases] = true
      else
        followup[:phrases] = phrases
      end
      Jobs.enqueue_in(1.minute, :sitemap_autolink_rebake_posts, followup)
    end

    private

    # Phrases arrive NORMALIZED — Matcher.normalize folds ’ and ‘ to a
    # straight apostrophe — but posts.raw is exactly what the member
    # typed. A post written "Foreman’s Field Guide" gets its link at cook
    # time and would be invisible to a `raw ILIKE '%foreman's…%'`
    # candidate filter, so ask for each spelling the matcher accepts.
    # Only apostrophe phrases pay the extra patterns.
    def raw_spellings(phrase)
      return [phrase] if !phrase.include?("'")
      [phrase, phrase.tr("'", "’"), phrase.tr("'", "‘")]
    end

    # The same phrase set the cook-time matcher links: manual mappings
    # plus active catalog terms, after the enabled-types, excluded-terms
    # and URL-pattern filters.
    def active_catalog_phrases
      (
        SitemapAutolink::Catalog.manual_mapping_rules +
          SitemapAutolink::Catalog.database_rules
      ).map { |r| r[:phrase] }
    end
  end
end
