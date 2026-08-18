import Controller from "@ember/controller";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import {
  BASE,
  catalogGet,
} from "discourse/plugins/discourse-sitemap-autolink/discourse/lib/sitemap-autolink-catalog";
import { i18n } from "discourse-i18n";

// Which sitemaps the plugin has found, and which of them it is allowed
// to import. A sitemap index expands to child sitemaps that routinely
// hold tens of thousands of URLs each; naming the index in a setting is
// not consent to import all of them, so they are listed here with their
// sizes and imported one decision at a time.
export default class AdminPluginsShowSitemapAutolinkSitemapsController extends Controller {
  @service dialog;

  @tracked data = null;
  @tracked pluginDisabled = false;
  @tracked loadFailed = false;
  @tracked loading = false;
  @tracked discovering = false;
  @tracked notice = null;

  get sitemaps() {
    return this.data?.sitemaps || [];
  }

  get pendingCount() {
    return this.data?.pending || 0;
  }

  // Sources named in the setting that no discovery pass has read yet:
  // until one runs there is nothing to show for them, which otherwise
  // looks like the setting was ignored.
  get undiscoveredSources() {
    const known = new Set(this.sitemaps.map((s) => s.url));
    return (this.data?.configured_sources || [])
      .map((row) => row.split(",")[0].trim())
      .filter((url) => url && !known.has(url));
  }

  @action
  async load() {
    this.loading = true;
    const result = await catalogGet("sitemaps/list");
    this.loading = false;
    this.pluginDisabled = !!result.pluginDisabled;
    this.loadFailed = !!result.failed;
    this.data = result.data || this.data;
  }

  @action
  async discover() {
    this.discovering = true;
    this.notice = null;
    try {
      const result = await ajax(`${BASE}/sitemaps/discover`, { type: "POST" });
      const problems = [...(result.errors || []), ...(result.notes || [])];
      this.notice = problems.length
        ? problems.join(" ")
        : i18n("sitemap_autolink.admin.discover_done");
      await this.load();
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.discovering = false;
    }
  }

  async #setStatus(sitemap, status, purge = false) {
    try {
      await ajax(`${BASE}/sitemaps/${sitemap.id}`, {
        type: "PUT",
        data: { status, purge: purge ? "true" : "false" },
      });
      await this.load();
    } catch (e) {
      popupAjaxError(e);
    }
  }

  @action
  importSitemap(sitemap) {
    this.#setStatus(sitemap, "enabled");
  }

  @action
  ignoreSitemap(sitemap) {
    this.#setStatus(sitemap, "ignored");
  }

  // Two separate ways to stop: keep the pages (they go to "gone from
  // sitemap" and come back if the sitemap is re-enabled) or delete them.
  // A single confirm cannot ask a question with three answers.
  // Purging one sitemap's dead pages without leaving the page that
  // shows you how many there are. The same thing is reachable from
  // Keywords by combining the sitemap and "gone from sitemap" filters —
  // this is just the short way round.
  @action
  purgeGone(sitemap) {
    if (!sitemap.gone_entries) {
      return;
    }
    this.dialog.yesNoConfirm({
      message: i18n("sitemap_autolink.admin.purge_sitemap_gone_confirm", {
        url: sitemap.url,
        count: sitemap.gone_entries,
      }),
      didConfirm: async () => {
        try {
          await ajax(`${BASE}/entries/purge`, {
            type: "DELETE",
            data: { filter: { sitemap: sitemap.url } },
          });
          await this.load();
        } catch (e) {
          popupAjaxError(e);
        }
      },
    });
  }

  @action
  stopImporting(sitemap) {
    this.dialog.yesNoConfirm({
      message: i18n("sitemap_autolink.admin.stop_importing_confirm", {
        url: sitemap.url,
        count: sitemap.live_entries,
      }),
      didConfirm: () => this.#setStatus(sitemap, "ignored"),
    });
  }

  @action
  stopAndPurge(sitemap) {
    this.dialog.yesNoConfirm({
      message: i18n("sitemap_autolink.admin.stop_and_purge_confirm", {
        url: sitemap.url,
        count: sitemap.entries,
      }),
      didConfirm: () => this.#setStatus(sitemap, "ignored", true),
    });
  }
}
