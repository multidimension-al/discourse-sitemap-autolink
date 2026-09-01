// One route per concern, so each is a real page in the plugin's admin
// nav with its own URL and its own data load — not tabs nested inside
// a single "Catalog" page.
//
// Every path here is prefixed. adminPlugins.show is mounted at
// /plugins/:plugin_id, and :plugin_id is a dynamic segment, so a child route's
// path is claimed for the whole site rather than for this plugin: `path: "logs"`
// matches /admin/plugins/ANY_PLUGIN/logs. When two installed plugins claim the
// same path, one of them loses its route with no error — that is exactly what
// happened between this plugin's "logs" page and discourse-indexnow's. Bare
// words like overview/logs/keywords are effectively global names, so they are
// prefixed to keep them ours.
export default {
  resource: "admin.adminPlugins.show",

  path: "/plugins",

  map() {
    this.route("discourse-sitemap-autolink-overview", { path: "autolink-overview" });
    this.route("discourse-sitemap-autolink-sitemaps", { path: "autolink-sitemaps" });
    this.route("discourse-sitemap-autolink-keywords", { path: "autolink-keywords" });
    this.route("discourse-sitemap-autolink-conflicts", { path: "autolink-conflicts" });
    this.route("discourse-sitemap-autolink-logs", { path: "autolink-logs" });
    // The catalog page these replaced; bookmarks land on the overview.
    this.route("discourse-sitemap-autolink-catalog", { path: "autolink-catalog" });
  },
};
