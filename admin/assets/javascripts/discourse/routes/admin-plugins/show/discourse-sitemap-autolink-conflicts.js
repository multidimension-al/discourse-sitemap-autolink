import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsShowSitemapAutolinkConflicts extends DiscourseRoute {
  setupController(controller, model) {
    super.setupController(controller, model);
    // Each catalog page owns its data and loads it on entry, so
    // arriving from the nav, a deep link or the back button all take
    // the same path.
    controller.load();
  }
}
