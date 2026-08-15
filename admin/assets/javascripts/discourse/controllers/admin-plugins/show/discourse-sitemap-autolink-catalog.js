import Controller from "@ember/controller";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

const BASE = "/admin/plugins/discourse-sitemap-autolink";
const POLL_INTERVAL = 5000;
const MAX_POLLS = 36;

export default class AdminPluginsShowSitemapAutolinkCatalogController extends Controller {
  @service dialog;

  @tracked status = null;
  @tracked runs = [];
  @tracked pendingTerms = [];
  @tracked pendingTotal = 0;
  @tracked entriesData = null;
  @tracked collisions = [];
  @tracked previewResult = null;
  @tracked previewLoading = false;
  @tracked notice = null;
  @tracked syncing = false;

  @tracked searchQuery = "";
  @tracked typeFilter = "";
  @tracked pendingOnly = false;
  @tracked page = 0;

  #pollCount = 0;
  #pollTimer = null;

  get entryTypes() {
    return this.entriesData?.types || [];
  }

  // "0 rules but entries exist" is almost always the enabled_types
  // setting filtering out every entry type — surface it as a diagnosis.
  get typesMismatch() {
    const s = this.status;
    if (!s || s.active_rules > 0 || s.active_entries === 0) {
      return null;
    }
    return {
      entry_types: (s.entry_types || []).join(", "),
      allowed: s.enabled_types_setting || i18n("sitemap_autolink.admin.all_types"),
    };
  }

  get pageDisplay() {
    return `${this.page + 1} / ${Math.max(this.entriesData?.pages || 1, 1)}`;
  }

  get hasPrevPage() {
    return this.page > 0;
  }

  get hasNextPage() {
    return this.page + 1 < (this.entriesData?.pages || 1);
  }

  entriesParams() {
    const data = { page: this.page };
    if (this.searchQuery) {
      data.q = this.searchQuery;
    }
    if (this.typeFilter) {
      data.type = this.typeFilter;
    }
    if (this.pendingOnly) {
      data.pending = "true";
    }
    return data;
  }

  @action
  async refreshAll() {
    const get = (path, data) => ajax(`${BASE}/${path}`, { data }).catch(() => null);
    const [status, runs, pending, collisions, entries] = await Promise.all([
      get("status"),
      get("runs"),
      get("pending"),
      get("collisions"),
      get("entries", this.entriesParams()),
    ]);
    this.status = status || this.status;
    this.runs = runs?.runs || this.runs;
    this.pendingTerms = pending?.pending || [];
    this.pendingTotal = pending?.total || 0;
    this.collisions = collisions?.collisions || [];
    this.entriesData = entries || this.entriesData;
  }

  @action
  async loadEntries() {
    try {
      this.entriesData = await ajax(`${BASE}/entries`, {
        data: this.entriesParams(),
      });
    } catch (e) {
      popupAjaxError(e);
    }
  }

  @action
  updateSearchQuery(event) {
    this.searchQuery = event.target.value;
  }

  @action
  search(event) {
    event?.preventDefault?.();
    this.page = 0;
    this.loadEntries();
  }

  @action
  setTypeFilter(event) {
    this.typeFilter = event.target.value;
    this.page = 0;
    this.loadEntries();
  }

  @action
  togglePendingOnly() {
    this.pendingOnly = !this.pendingOnly;
    this.page = 0;
    this.loadEntries();
  }

  @action
  prevPage() {
    if (this.hasPrevPage) {
      this.page -= 1;
      this.loadEntries();
    }
  }

  @action
  nextPage() {
    if (this.hasNextPage) {
      this.page += 1;
      this.loadEntries();
    }
  }

  @action
  async syncNow() {
    try {
      await ajax(`${BASE}/sync`, { type: "POST" });
      this.syncing = true;
      this.notice = i18n("sitemap_autolink.admin.sync_started");
      this.#pollCount = 0;
      this.#scheduleSyncPoll(this.runs[0]?.id);
    } catch (e) {
      popupAjaxError(e);
    }
  }

  #scheduleSyncPoll(lastRunId) {
    clearTimeout(this.#pollTimer);
    this.#pollTimer = setTimeout(async () => {
      this.#pollCount += 1;
      const runs = await ajax(`${BASE}/runs`).catch(() => null);
      const newest = runs?.runs?.[0];
      const finishedNewRun =
        newest && newest.id !== lastRunId && newest.finished_at;
      if (finishedNewRun) {
        this.syncing = false;
        this.notice = newest.success
          ? i18n("sitemap_autolink.admin.sync_finished")
          : i18n("sitemap_autolink.admin.sync_failed");
        await this.refreshAll();
      } else if (this.#pollCount < MAX_POLLS) {
        if (runs) {
          this.runs = runs.runs;
        }
        this.#scheduleSyncPoll(lastRunId);
      } else {
        this.syncing = false;
        this.notice = i18n("sitemap_autolink.admin.sync_still_running");
      }
    }, POLL_INTERVAL);
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
      this.pendingTotal = Math.max(this.pendingTotal - 1, 0);
    } catch (e) {
      popupAjaxError(e);
    }
  }

  @action
  bulkPending(state) {
    const count = this.pendingTerms.length;
    this.dialog.yesNoConfirm({
      message: i18n(`sitemap_autolink.admin.bulk_${state}_confirm`, { count }),
      didConfirm: async () => {
        try {
          await ajax(`${BASE}/terms/bulk`, {
            type: "PUT",
            data: { ids: this.pendingTerms.map((t) => t.id), state },
          });
          await this.refreshAll();
        } catch (e) {
          popupAjaxError(e);
        }
      },
    });
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
}
