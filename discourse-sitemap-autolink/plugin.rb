# frozen_string_literal: true

# name: discourse-sitemap-autolink
# about: Automatic internal linking of GBFans shop products, categories and wiki articles in posts, driven by a sitemap-synced server-side catalog.
# version: 0.1.0
# authors: GBFans.com
# url: https://github.com/ajquick/discourse-sitemap-autolink
# required_version: 3.4.0

enabled_site_setting :gbfans_autolink_enabled

module ::GbfansAutolink
  PLUGIN_NAME = "discourse-sitemap-autolink"
end

require_relative "lib/gbfans_autolink/matcher"
require_relative "lib/gbfans_autolink/ruleset"
require_relative "lib/gbfans_autolink/link_applier"

after_initialize do
  require_relative "lib/gbfans_autolink/catalog"
  require_relative "lib/gbfans_autolink/term_generator"
  require_relative "lib/gbfans_autolink/sitemap_sync"
  require_relative "app/models/gbfans_autolink_entry"
  require_relative "app/models/gbfans_autolink_term"
  require_relative "app/jobs/scheduled/gbfans_autolink_daily_sync"
  require_relative "app/jobs/regular/gbfans_autolink_selective_rebake"
  require_relative "app/controllers/gbfans_autolink_admin_controller"

  # The linking hook. Runs inside CookedPostProcessor AFTER core
  # processing (nofollow enforcement, oneboxes, image work), on a doc
  # that was freshly re-cooked from Post#raw — so links never stack,
  # raw is never touched, and a rebake always reflects the current
  # catalog. Jobs::ProcessPost persists the mutated doc.
  on(:post_process_cooked) do |doc, post|
    begin
      if SiteSetting.gbfans_autolink_enabled && GbfansAutolink::Catalog.linkable_post?(post)
        GbfansAutolink::LinkApplier.apply!(
          doc,
          GbfansAutolink::Catalog.ruleset,
          max_per_destination: SiteSetting.gbfans_autolink_max_links_per_destination_per_post,
          max_total: SiteSetting.gbfans_autolink_max_links_per_post,
          skip_quotes: SiteSetting.gbfans_autolink_skip_quotes,
          base_url: SiteSetting.gbfans_autolink_base_url,
        )
      end
    rescue => e
      # Linking must never break post processing.
      Rails.logger.warn(
        "gbfans-autolink: failed to process post #{post&.id}: #{e.class} #{e.message}",
      )
    end
  end

  Discourse::Application.routes.append do
    namespace :admin, constraints: StaffConstraint.new do
      scope "/plugins/sitemap-autolink" do
        get "entries" => "gbfans_autolink_admin#entries"
        post "entries" => "gbfans_autolink_admin#create_entry"
        put "entries/:id" => "gbfans_autolink_admin#update_entry"
        post "terms" => "gbfans_autolink_admin#create_term"
        put "terms/:id" => "gbfans_autolink_admin#update_term"
        delete "terms/:id" => "gbfans_autolink_admin#destroy_term"
        get "collisions" => "gbfans_autolink_admin#collisions"
        get "pending" => "gbfans_autolink_admin#pending"
        get "status" => "gbfans_autolink_admin#status"
        post "sync" => "gbfans_autolink_admin#sync"
        post "rebuild" => "gbfans_autolink_admin#rebuild"
        post "rebake" => "gbfans_autolink_admin#rebake"
      end
    end
  end
end
