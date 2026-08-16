export default {
  resource: "admin.adminPlugins.show",

  path: "/plugins",

  map() {
    this.route("discourse-sitemap-autolink-catalog", { path: "catalog" });
  },
};
