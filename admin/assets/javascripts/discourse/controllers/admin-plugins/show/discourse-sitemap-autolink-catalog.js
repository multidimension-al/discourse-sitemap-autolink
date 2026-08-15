import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

const BASE = "/admin/plugins/discourse-sitemap-autolink";

export default class AdminPluginsShowSitemapAutolinkCatalogController extends Controller {
  @tracked pendingTerms = [];
  @tracked entriesData = null;
  @tracked previewResult = null;
  @tracked previewLoading = false;
  @tracked searchQuery = "";
  @tracked notice = null;

  @action
  async syncNow() {
    try {
      await ajax(`${BASE}/sync`, { type: "POST" });
      this.notice = i18n("sitemap_autolink.admin.sync_queued");
    } catch (e) {
      popupAjaxError(e);
    }
  }

  @action
  async runPreview() {
    this.previewLoading = true;
    try {
      this.previewResult = await ajax(`${BASE}/preview`, {
        type: "POST",
        data: { limit: 5 },
      });
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.previewLoading = false;
    }
  }

  @action
  async setTermState(term, state) {
    try {
      await ajax(`${BASE}/terms/${term.id}`, { type: "PUT", data: { state } });
      this.pendingTerms = this.pendingTerms.filter((t) => t.id !== term.id);
      this.notice = i18n("sitemap_autolink.admin.term_updated");
    } catch (e) {
      popupAjaxError(e);
    }
  }

  @action
  async toggleEntry(entry) {
    try {
      const updated = await ajax(`${BASE}/entries/${entry.id}`, {
        type: "PUT",
        data: { enabled: entry.enabled ? "false" : "true" },
      });
      this.entriesData = {
        ...this.entriesData,
        entries: this.entriesData.entries.map((e) =>
          e.id === entry.id ? updated : e
        ),
      };
    } catch (e) {
      popupAjaxError(e);
    }
  }

  @action
  updateSearchQuery(event) {
    this.searchQuery = event.target.value;
  }

  @action
  async search(event) {
    event?.preventDefault?.();
    try {
      this.entriesData = await ajax(`${BASE}/entries`, {
        data: { q: this.searchQuery },
      });
    } catch (e) {
      popupAjaxError(e);
    }
  }
}
