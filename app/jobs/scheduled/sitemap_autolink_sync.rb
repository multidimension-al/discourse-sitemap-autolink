# frozen_string_literal: true

module Jobs
  # Daily sitemap → catalog synchronization. Post cooking never fetches
  # anything; this job is the only place remote content is read.
  class SitemapAutolinkSync < ::Jobs::Scheduled
    every 1.day

    def execute(_args)
      return if !SiteSetting.sitemap_autolink_enabled
      return if !SiteSetting.sitemap_autolink_sync_enabled
      return if SiteSetting.sitemap_autolink_sources.blank?

      report = SitemapAutolink::SitemapSync.new.run!

      Rails.logger.info(
        "sitemap-autolink sync: #{report[:seen]} urls seen, " \
          "#{report[:added].size} added, #{report[:title_changed].size} retitled, " \
          "#{report[:removed].size} removed, #{report[:errors].size} errors",
      )

      if SiteSetting.sitemap_autolink_auto_rebake_on_changes
        phrases = (report[:phrases_added] + report[:phrases_removed]).uniq
        phrases.each do |phrase|
          Jobs.enqueue(:sitemap_autolink_selective_rebake, phrase: phrase)
        end
      end
    end
  end
end
