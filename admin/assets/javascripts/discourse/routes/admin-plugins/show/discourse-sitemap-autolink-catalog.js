import DiscourseRoute from "discourse/routes/discourse";
import { service } from "@ember/service";

// The single catalog page these four routes replaced. Bookmarks and
// links to it still work; they land on the overview.
export default class AdminPluginsShowSitemapAutolinkCatalog extends DiscourseRoute {
  @service router;

  beforeModel() {
    this.router.replaceWith(
      "adminPlugins.show.discourse-sitemap-autolink-overview"
    );
  }
}
