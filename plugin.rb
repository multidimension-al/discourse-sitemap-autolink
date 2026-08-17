# frozen_string_literal: true

# name: discourse-sitemap-autolink
# about: Automatically links the first mention of your site's pages (products, wiki articles, docs, …) in posts, driven by a sitemap-synced server-side catalog.
# version: 1.0.0
# authors: AJ Quick
# url: https://github.com/multidimension-al/discourse-sitemap-autolink
# required_version: 3.4.0

enabled_site_setting :sitemap_autolink_enabled

register_asset "stylesheets/sitemap-autolink-admin.scss"

module ::SitemapAutolink
  PLUGIN_NAME = "discourse-sitemap-autolink"
end

require_relative "lib/sitemap_autolink/matcher"
require_relative "lib/sitemap_autolink/ruleset"
require_relative "lib/sitemap_autolink/link_applier"
require_relative "lib/sitemap_autolink/url_filter"

add_admin_route "sitemap_autolink.title", "discourse-sitemap-autolink", use_new_show_route: true

after_initialize do
  require_relative "lib/sitemap_autolink/catalog"
  require_relative "lib/sitemap_autolink/term_generator"
  require_relative "lib/sitemap_autolink/sitemap_sync"
  require_relative "app/models/sitemap_autolink_entry"
  require_relative "app/models/sitemap_autolink_term"
  require_relative "app/models/sitemap_autolink_sync_run"
  require_relative "app/jobs/scheduled/sitemap_autolink_sync"
  require_relative "app/jobs/regular/sitemap_autolink_rebake_posts"
  require_relative "app/jobs/regular/sitemap_autolink_selective_rebake"
  require_relative "app/controllers/sitemap_autolink_admin_controller"

  # The linking hook. Runs inside CookedPostProcessor AFTER core
  # processing (nofollow enforcement, oneboxes, image work), on a doc
  # that was freshly re-cooked from Post#raw — so links never stack,
  # raw is never touched, and a rebake always reflects the current
  # catalog. Jobs::ProcessPost persists the mutated doc.
  on(:post_process_cooked) do |doc, post|
    begin
      if SiteSetting.sitemap_autolink_enabled && SitemapAutolink::Catalog.linkable_post?(post)
        SitemapAutolink::LinkApplier.apply!(
          doc,
          SitemapAutolink::Catalog.ruleset,
          max_per_destination:
            SiteSetting.sitemap_autolink_max_links_per_destination_per_post,
          max_total: SiteSetting.sitemap_autolink_max_links_per_post,
          skip_quotes: SiteSetting.sitemap_autolink_skip_quotes,
        )
      end
    rescue => e
      # Linking must never break post processing.
      Rails.logger.warn(
        "sitemap-autolink: failed to process post #{post&.id}: #{e.class} #{e.message}",
      )
    end
  end

  Discourse::Application.routes.append do
    # Full-page load of the custom admin pages: core only routes
    # /admin/plugins/:plugin_id and .../settings, so each custom page
    # URL needs an explicit Rails route rendering the app shell (same
    # pattern as discourse-subscriptions). "catalog" is the single page
    # these four replaced; its Ember route redirects to the overview.
    %w[overview keywords conflicts logs catalog].each do |page|
      get "/admin/plugins/discourse-sitemap-autolink/#{page}" => "admin/plugins#index",
          :constraints => StaffConstraint.new
    end

    # JSON management API. Deliberately NOT inside `namespace :admin` —
    # that would resolve the controller as Admin::…; the controller is a
    # top-level class (auth enforced by Admin::AdminController it
    # inherits from, plus the StaffConstraint here).
    # `defaults: { format: :json }` is load-bearing, not decoration. An
    # admin-namespaced request that arrives asking for HTML is answered
    # with the admin SPA shell before this controller's own filters run
    # — so without it these endpoints return a page of HTML to anything
    # that does not set an Accept header (curl, a script, a spec), and
    # `requires_plugin` never gets to refuse a disabled plugin.
    scope "/admin/plugins/discourse-sitemap-autolink",
          constraints: StaffConstraint.new,
          defaults: {
            format: :json,
          } do
      get "entries" => "sitemap_autolink_admin#entries"
      post "entries" => "sitemap_autolink_admin#create_entry"
      put "entries/:id" => "sitemap_autolink_admin#update_entry"
      get "terms" => "sitemap_autolink_admin#terms"
      post "terms" => "sitemap_autolink_admin#create_term"
      put "terms/bulk" => "sitemap_autolink_admin#bulk_terms"
      put "terms/:id" => "sitemap_autolink_admin#update_term"
      delete "terms/:id" => "sitemap_autolink_admin#destroy_term"
      get "collisions" => "sitemap_autolink_admin#collisions"
      get "overlaps" => "sitemap_autolink_admin#overlaps"
      get "status" => "sitemap_autolink_admin#status"
      get "runs" => "sitemap_autolink_admin#runs"
      post "preview" => "sitemap_autolink_admin#preview"
      post "sync" => "sitemap_autolink_admin#sync"
      post "rebuild" => "sitemap_autolink_admin#rebuild"
      post "sync/cancel" => "sitemap_autolink_admin#cancel_sync"
      post "rebake" => "sitemap_autolink_admin#rebake"
    end
  end
end
