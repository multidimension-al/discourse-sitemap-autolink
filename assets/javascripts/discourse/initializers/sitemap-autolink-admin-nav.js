import { withPluginApi } from "discourse/lib/plugin-api";

const PLUGIN_ID = "discourse-sitemap-autolink";

const PAGES = ["overview", "keywords", "conflicts", "logs"];

export default {
  name: "sitemap-autolink-admin-nav",

  initialize(container) {
    const currentUser = container.lookup("service:current-user");
    if (!currentUser?.admin) {
      return;
    }

    withPluginApi((api) => {
      api.addAdminPluginConfigurationNav(
        PLUGIN_ID,
        PAGES.map((page) => ({
          label: `sitemap_autolink.admin.nav.${page}`,
          route: `adminPlugins.show.discourse-sitemap-autolink-${page}`,
        }))
      );
    });
  },
};
