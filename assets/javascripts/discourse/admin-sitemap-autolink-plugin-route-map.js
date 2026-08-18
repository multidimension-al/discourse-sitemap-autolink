export default {
  resource: "admin.adminPlugins.show",

  path: "/plugins",

  // One route per concern, so each is a real page in the plugin's admin
  // nav with its own URL and its own data load — not tabs nested inside
  // a single "Catalog" page.
  map() {
    this.route("discourse-sitemap-autolink-overview", { path: "overview" });
    this.route("discourse-sitemap-autolink-sitemaps", { path: "sitemaps" });
    this.route("discourse-sitemap-autolink-keywords", { path: "keywords" });
    this.route("discourse-sitemap-autolink-conflicts", { path: "conflicts" });
    this.route("discourse-sitemap-autolink-logs", { path: "logs" });
    // The catalog page these replaced; bookmarks land on the overview.
    this.route("discourse-sitemap-autolink-catalog", { path: "catalog" });
  },
};
