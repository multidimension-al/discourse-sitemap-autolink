import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsShowSitemapAutolinkCatalog extends DiscourseRoute {
  async model() {
    // Each section loads independently — one failing endpoint shows an
    // inline error instead of taking down the whole page.
    const get = (path) =>
      ajax(`/admin/plugins/sitemap-autolink/${path}`).catch(() => null);
    const [status, runs, pending, collisions, entries] = await Promise.all([
      get("status"),
      get("runs"),
      get("pending"),
      get("collisions"),
      get("entries"),
    ]);
    return {
      status: status || {},
      runs: runs?.runs || [],
      pending: pending?.pending || [],
      collisions: collisions?.collisions || [],
      entries: entries || { total: 0, entries: [] },
      loadFailed: !status,
    };
  }

  setupController(controller, model) {
    super.setupController(controller, model);
    controller.pendingTerms = model.pending;
    controller.entriesData = model.entries;
  }
}
