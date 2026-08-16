# frozen_string_literal: true

module Jobs
  # Superseded by Jobs::SitemapAutolinkRebakePosts. This version
  # enqueued ONE JOB PER CHANGED PHRASE, so a catalog-scale sync (the
  # first import of a large sitemap) could flood Sidekiq with tens of
  # thousands of jobs. Kept as a no-op tombstone so jobs still sitting
  # in the queue from an older build drain instantly and harmlessly
  # after an upgrade instead of erroring or rebaking anything.
  class SitemapAutolinkSelectiveRebake < ::Jobs::Base
    sidekiq_options queue: "low"

    def execute(_args)
      # Log at most once per 5 minutes no matter how many stale jobs drain.
      if Discourse.redis.set("sitemap_autolink_stale_rebake_notice", "1", ex: 300, nx: true)
        Rails.logger.warn(
          "sitemap-autolink: draining queued per-phrase selective-rebake jobs " \
            "from a previous plugin version as no-ops (replaced by the batched " \
            "sitemap_autolink_rebake_posts job); it is safe to delete any remaining " \
            "Jobs::SitemapAutolinkSelectiveRebake jobs from the 'low' queue",
        )
      end
    end
  end
end
