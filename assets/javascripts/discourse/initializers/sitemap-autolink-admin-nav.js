import getURL from "discourse/lib/get-url";
import { withPluginApi } from "discourse/lib/plugin-api";

const PLUGIN_ID = "discourse-sitemap-autolink";
const BASE_URL = "/admin/plugins/discourse-sitemap-autolink";

// page => the path its route is mounted at (see the route map; paths are
// prefixed to stay out of the shared /admin/plugins/:plugin_id/* namespace).
const PAGES = {
  overview: "autolink-overview",
  sitemaps: "autolink-sitemaps",
  keywords: "autolink-keywords",
  conflicts: "autolink-conflicts",
  logs: "autolink-logs",
};

/**
 * Registers this plugin's pages in the admin plugin nav, skipping any whose
 * route the router cannot actually resolve.
 *
 * Core's adminPlugins.show.index route calls replaceWith() on the first
 * non-settings entry in a plugin's config nav, unconditionally. So a nav entry
 * whose route is missing is not a missing tab: it throws "There is no route
 * named ..." on every visit to the plugin's admin page, Ember retries, and with
 * a theme that renders site chrome in an outlet the retries stack headers until
 * the browser tab runs out of memory.
 *
 * A route can go missing without any error. Paths under adminPlugins.show are
 * shared by every installed plugin, so two plugins claiming one path means the
 * loser's route is simply dropped; and mapRoutes() discards a `resource:` route
 * map silently when tree.findPath("admin.adminPlugins.show") misses:
 *
 *     extras.forEach((extra) => {
 *       let node = tree.findPath(extra.resource);
 *       if (node) { node.extract(extra.map); }
 *     });
 *
 * so registration cannot be assumed to have worked. The check is deferred because
 * the router is not set up during instance-initializers, where hasRoute() throws.
 *
 * It is also retried rather than made once. Admin routes live in a chunk that is
 * loaded separately, so on a boot that starts outside the admin panel the first
 * transition can resolve these URLs to core's catch-all simply because those
 * routes are not in the recognizer yet. Checking once and giving up leaves the
 * tabs permanently missing on a working site, so both edges of a transition are
 * watched and the listeners stay attached until the routes actually resolve.
 */
export default {
  name: "sitemap-autolink-admin-nav",

  initialize(container) {
    const currentUser = container.lookup("service:current-user");
    if (!currentUser?.admin) {
      return;
    }

    const router = container.lookup("service:router");
    if (!router) {
      return;
    }

    const register = () => {
      const links = Object.entries(PAGES)
        .filter(([page, path]) => this.routeExists(router, page, path))
        .map(([page]) => ({
          label: `sitemap_autolink.admin.nav.${page}`,
          route: `adminPlugins.show.discourse-sitemap-autolink-${page}`,
        }));

      // Keep listening until the routes resolve; admin routes may arrive later.
      if (links.length === 0) {
        return;
      }

      router.off("routeWillChange", register);
      router.off("routeDidChange", register);

      withPluginApi((api) => {
        api.addAdminPluginConfigurationNav(PLUGIN_ID, links);
      });
    };

    router.on("routeWillChange", register);
    router.on("routeDidChange", register);
  },

  /**
   * True when the router resolves this page's URL to this page's route.
   *
   * recognize() is the public way to ask whether a route exists; when the route
   * was dropped the URL falls through to core's catch-all and the name will not
   * match. Anything unexpected counts as absent: failing to advertise a tab is
   * recoverable, advertising a missing one is not.
   */
  routeExists(router, page, path) {
    try {
      return (
        router.recognize(getURL(`${BASE_URL}/${path}`))?.name ===
        `adminPlugins.show.discourse-sitemap-autolink-${page}`
      );
    } catch {
      return false;
    }
  },
};
