import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsShowSitemapAutolinkCatalog extends DiscourseRoute {
  setupController(controller, model) {
    super.setupController(controller, model);
    // The controller owns all page data (tracked, refreshable, polled
    // after syncs); kick off the initial load.
    controller.refreshAll();
  }
}
