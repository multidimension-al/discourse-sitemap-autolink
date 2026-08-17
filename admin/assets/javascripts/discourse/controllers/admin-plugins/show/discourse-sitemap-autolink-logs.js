import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { catalogGet } from "discourse/plugins/discourse-sitemap-autolink/discourse/lib/sitemap-autolink-catalog";

export default class AdminPluginsShowSitemapAutolinkLogsController extends Controller {
  @tracked runs = null;
  @tracked pluginDisabled = false;
  @tracked loadFailed = false;

  @action
  async load() {
    const result = await catalogGet("runs");
    this.pluginDisabled = !!result.pluginDisabled;
    this.loadFailed = !!result.failed;
    this.runs = result.data?.runs || null;
  }
}
