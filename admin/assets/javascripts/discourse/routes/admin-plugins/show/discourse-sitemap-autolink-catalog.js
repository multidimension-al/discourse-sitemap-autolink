import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsShowSitemapAutolinkCatalog extends DiscourseRoute {
  async model() {
    const [status, runs, pending, collisions, entries] = await Promise.all([
      ajax("/admin/plugins/sitemap-autolink/status"),
      ajax("/admin/plugins/sitemap-autolink/runs"),
      ajax("/admin/plugins/sitemap-autolink/pending"),
      ajax("/admin/plugins/sitemap-autolink/collisions"),
      ajax("/admin/plugins/sitemap-autolink/entries"),
    ]);
    return {
      status,
      runs: runs.runs,
      pending: pending.pending,
      collisions: collisions.collisions,
      entries,
    };
  }

  setupController(controller, model) {
    super.setupController(controller, model);
    controller.pendingTerms = model.pending;
    controller.entriesData = model.entries;
  }
}
