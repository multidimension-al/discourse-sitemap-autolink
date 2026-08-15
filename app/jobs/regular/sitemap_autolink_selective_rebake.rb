# frozen_string_literal: true

module Jobs
  # Rebakes posts likely affected by one changed/removed phrase, in
  # bounded batches (modeled on core's Jobs::RebakeCustomEmojiPosts,
  # plus rate limiting). raw ILIKE is only a candidate filter — the
  # cook-time matcher decides whether a link actually appears.
  class SitemapAutolinkSelectiveRebake < ::Jobs::Base
    sidekiq_options queue: "low"

    def execute(args)
      phrase = args[:phrase].to_s
      return if phrase.length < 3

      budget = SiteSetting.sitemap_autolink_max_rebakes_per_job_run
      after_id = args[:after_id].to_i

      batch =
        Post
          .where(deleted_at: nil)
          .where("posts.id > ?", after_id)
          .where("posts.raw ILIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(phrase)}%")
          .order(:id)
          .limit(budget)
          .to_a

      batch.each do |post|
        begin
          post.rebake!(priority: :low)
        rescue => e
          Rails.logger.warn(
            "sitemap-autolink rebake failed for post #{post.id}: #{e.message}",
          )
        end
      end

      if batch.size == budget
        Jobs.enqueue_in(
          1.minute,
          :sitemap_autolink_selective_rebake,
          phrase: phrase,
          after_id: batch.last.id,
        )
      end
    end
  end
end
