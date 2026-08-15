import { withPluginApi } from "discourse/lib/plugin-api";

const PLUGIN_ID = "discourse-sitemap-autolink";

export default {
  name: "sitemap-autolink-admin-nav",

  initialize(container) {
    const currentUser = container.lookup("service:current-user");
    if (!currentUser?.admin) {
      return;
    }

    withPluginApi((api) => {
      api.addAdminPluginConfigurationNav(PLUGIN_ID, [
        {
          label: "sitemap_autolink.admin.catalog_title",
          route: "adminPlugins.show.discourse-sitemap-autolink-catalog",
        },
      ]);
    });
  },
};
