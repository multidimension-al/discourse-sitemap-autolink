import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsShowSitemapAutolinkCatalog extends DiscourseRoute {
  // The tab lives in the URL, so a tab is linkable, survives a reload
  // and works with the back button. Refreshing the model on a tab
  // change means every entry into a tab — link, deep link or back —
  // runs through the same load path.
  queryParams = { tab: { refreshModel: true } };

  setupController(controller, model) {
    super.setupController(controller, model);
    // The controller owns all page data (tracked, refreshable, polled
    // after syncs); kick off the load for whichever tab is showing.
    controller.load();
  }
}
