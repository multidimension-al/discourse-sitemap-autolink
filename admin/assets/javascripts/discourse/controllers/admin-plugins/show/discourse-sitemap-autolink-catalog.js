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

// One concern per tab. A catalog fed by a few thousand sitemap URLs
// carries tens of thousands of phrases, and putting the review queue,
// the keyword list, the conflict report and the sync history on one
// page made all four unusable at once. Each tab loads only its own
// data, and only when it is first opened.
const TABS = ["overview", "keywords", "pages", "conflicts", "logs"];

export default class AdminPluginsShowSitemapAutolinkCatalogController extends Controller {
  @service dialog;

  queryParams = ["tab"];

  @tracked tab = "overview";

  @tracked status = null;
  @tracked runs = null;
  @tracked pluginDisabled = false;
  @tracked notice = null;
  @tracked syncing = false;
  @tracked previewResult = null;
  @tracked previewLoading = false;

  // Keywords tab: one row per phrase, server-paged and server-searched.
  @tracked termsData = null;
  @tracked termQuery = "";
  @tracked termState = "";
  @tracked termType = "";
  @tracked termPage = 0;

  // Pages tab: one row per ingested URL, with its phrases.
  @tracked entriesData = null;
  @tracked searchQuery = "";
  @tracked typeFilter = "";
  @tracked pendingOnly = false;
  @tracked page = 0;

  // Conflicts tab: same phrase claimed twice, and phrases buried inside
  // longer ones.
  @tracked collisionsData = null;
  @tracked overlapsData = null;
  @tracked conflictQuery = "";
  @tracked collisionPage = 0;
  @tracked overlapPage = 0;

  #pollCount = 0;
  #pollTimer = null;
  #loadedTabs = new Set();
  #headerLoaded = false;

  // Controllers are singletons that outlive the page: without this a
  // sync poll scheduled here keeps firing (and re-rendering) long after
  // the admin has navigated away.
  willDestroy() {
    super.willDestroy(...arguments);
    clearTimeout(this.#pollTimer);
  }

  get activeTab() {
    return TABS.includes(this.tab) ? this.tab : TABS[0];
  }

  get entryTypes() {
    return this.entriesData?.types || this.termsData?.types || [];
  }

  get pendingCount() {
    return this.status?.pending_terms || 0;
  }

  get termStateCounts() {
    return this.termsData?.state_counts || {};
  }

  // The counts are for the search and type filter WITHOUT the state
  // filter, so "All" keeps meaning the same thing while a state chip is
  // selected and `termsData.total` has narrowed to that state.
  get termsTotal() {
    return Object.values(this.termStateCounts).reduce((sum, n) => sum + n, 0);
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
      allowed:
        s.enabled_types_setting || i18n("sitemap_autolink.admin.all_types"),
    };
  }

  #display(data, page) {
    return `${page + 1} / ${Math.max(data?.pages || 1, 1)}`;
  }

  #hasNext(data, page) {
    return page + 1 < (data?.pages || 1);
  }

  get pageDisplay() {
    return this.#display(this.entriesData, this.page);
  }

  get hasPrevPage() {
    return this.page > 0;
  }

  get hasNextPage() {
    return this.#hasNext(this.entriesData, this.page);
  }

  get termsPageDisplay() {
    return this.#display(this.termsData, this.termPage);
  }

  get hasPrevTermsPage() {
    return this.termPage > 0;
  }

  get hasNextTermsPage() {
    return this.#hasNext(this.termsData, this.termPage);
  }

  get collisionsPageDisplay() {
    return this.#display(this.collisionsData, this.collisionPage);
  }

  get hasPrevCollisionsPage() {
    return this.collisionPage > 0;
  }

  get hasNextCollisionsPage() {
    return this.#hasNext(this.collisionsData, this.collisionPage);
  }

  get overlapsPageDisplay() {
    return this.#display(this.overlapsData, this.overlapPage);
  }

  get hasPrevOverlapsPage() {
    return this.overlapPage > 0;
  }

  get hasNextOverlapsPage() {
    return this.#hasNext(this.overlapsData, this.overlapPage);
  }

  // While sitemap_autolink_enabled is off, `requires_plugin` answers
  // 404 for every endpoint on this page. That is a diagnosis, not an
  // outage — and it is the one an admin opening this page for the
  // first time most needs to read, so it must not be reported as
  // "something failed, check your logs".
  //
  // Any other failure returns null too — callers keep whatever they were
  // showing rather than redrawing an empty list, which would read as "no
  // results for this filter" — and says so once in the page notice.
  async #get(path, data) {
    try {
      return await ajax(`${BASE}/${path}`, { data });
    } catch (error) {
      if (error?.jqXHR?.status === 404) {
        this.pluginDisabled = true;
      } else {
        this.notice = i18n("sitemap_autolink.admin.load_failed");
      }
      return null;
    }
  }

  // Called on entry and on every tab change (the tab is a query param,
  // so the route refreshes). Status and history back the page header on
  // every tab — everything else waits until its tab is opened.
  @action
  async load() {
    if (!this.#headerLoaded) {
      this.#headerLoaded = true;
      const [status, runs] = await Promise.all([
        this.#get("status"),
        this.#get("runs"),
      ]);
      this.status = status;
      this.runs = runs?.runs || [];
    }
    const tab = this.activeTab;
    if (!this.#loadedTabs.has(tab)) {
      this.#loadedTabs.add(tab);
      await this.#loadTabData(tab);
    }
  }

  #loadTabData(tab) {
    switch (tab) {
      case "keywords":
        return this.loadTerms();
      case "pages":
        return this.loadEntries();
      case "conflicts":
        return Promise.all([this.loadCollisions(), this.loadOverlaps()]);
      default:
        return Promise.resolve();
    }
  }

  @action
  async refreshAll() {
    this.#headerLoaded = false;
    this.#loadedTabs.clear();
    await this.load();
  }

  async #reloadStatus() {
    this.status = (await this.#get("status")) || this.status;
  }

  termParams() {
    const data = { page: this.termPage };
    if (this.termQuery) {
      data.q = this.termQuery;
    }
    if (this.termState) {
      data.state = this.termState;
    }
    if (this.termType) {
      data.type = this.termType;
    }
    return data;
  }

  @action
  async loadTerms() {
    this.termsData =
      (await this.#get("terms", this.termParams())) || this.termsData;
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
  async loadEntries() {
    this.entriesData =
      (await this.#get("entries", this.entriesParams())) || this.entriesData;
  }

  @action
  async loadCollisions() {
    const data = { page: this.collisionPage };
    if (this.conflictQuery) {
      data.q = this.conflictQuery;
    }
    this.collisionsData =
      (await this.#get("collisions", data)) || this.collisionsData;
  }

  @action
  async loadOverlaps() {
    const data = { page: this.overlapPage };
    if (this.conflictQuery) {
      data.q = this.conflictQuery;
    }
    this.overlapsData =
      (await this.#get("overlaps", data)) || this.overlapsData;
  }

  @action
  updateTermQuery(event) {
    this.termQuery = event.target.value;
  }

  @action
  searchTerms(event) {
    event?.preventDefault?.();
    this.termPage = 0;
    this.loadTerms();
  }

  @action
  setTermStateFilter(state) {
    this.termState = state;
    this.termPage = 0;
    this.loadTerms();
  }

  @action
  setTermTypeFilter(event) {
    this.termType = event.target.value;
    this.termPage = 0;
    this.loadTerms();
  }

  @action
  prevTermsPage() {
    if (this.hasPrevTermsPage) {
      this.termPage -= 1;
      this.loadTerms();
    }
  }

  @action
  nextTermsPage() {
    if (this.hasNextTermsPage) {
      this.termPage += 1;
      this.loadTerms();
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
  updateConflictQuery(event) {
    this.conflictQuery = event.target.value;
  }

  @action
  searchConflicts(event) {
    event?.preventDefault?.();
    this.collisionPage = 0;
    this.overlapPage = 0;
    this.loadCollisions();
    this.loadOverlaps();
  }

  @action
  prevCollisionsPage() {
    if (this.hasPrevCollisionsPage) {
      this.collisionPage -= 1;
      this.loadCollisions();
    }
  }

  @action
  nextCollisionsPage() {
    if (this.hasNextCollisionsPage) {
      this.collisionPage += 1;
      this.loadCollisions();
    }
  }

  @action
  prevOverlapsPage() {
    if (this.hasPrevOverlapsPage) {
      this.overlapPage -= 1;
      this.loadOverlaps();
    }
  }

  @action
  nextOverlapsPage() {
    if (this.hasNextOverlapsPage) {
      this.overlapPage += 1;
      this.loadOverlaps();
    }
  }

  @action
  async syncNow() {
    try {
      await ajax(`${BASE}/sync`, { type: "POST" });
      this.syncing = true;
      this.notice = i18n("sitemap_autolink.admin.sync_started");
      this.#pollCount = 0;
      this.#scheduleSyncPoll(this.runs?.[0]?.id);
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

  get syncRunning() {
    return this.syncing || this.runs?.[0]?.result === "running";
  }

  @action
  async cancelSync() {
    try {
      await ajax(`${BASE}/sync/cancel`, { type: "POST" });
      this.notice = i18n("sitemap_autolink.admin.cancel_requested");
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
  rebakeAll() {
    this.dialog.yesNoConfirm({
      message: i18n("sitemap_autolink.admin.rebake_all_confirm"),
      didConfirm: async () => {
        try {
          await ajax(`${BASE}/rebake`, {
            type: "POST",
            data: { all: "true" },
          });
          this.notice = i18n("sitemap_autolink.admin.rebake_all_started");
        } catch (e) {
          popupAjaxError(e);
        }
      },
    });
  }

  // Bulk over the whole current filter, not just the rows on screen:
  // clearing a queue of thousands of phrases 50 at a time is not review.
  // The confirmation names the exact count first.
  @action
  bulkTerms(state) {
    const count = this.termsData?.total || 0;
    if (count === 0) {
      return;
    }
    this.dialog.yesNoConfirm({
      message: i18n(`sitemap_autolink.admin.bulk_${state}_confirm`, { count }),
      didConfirm: async () => {
        try {
          await ajax(`${BASE}/terms/bulk`, {
            type: "PUT",
            data: {
              state,
              filter: {
                q: this.termQuery,
                state: this.termState,
                type: this.termType,
              },
            },
          });
          await Promise.all([this.loadTerms(), this.#reloadStatus()]);
        } catch (e) {
          popupAjaxError(e);
        }
      },
    });
  }

  #replaceTerm(term, updated) {
    this.termsData = {
      ...this.termsData,
      terms: this.termsData.terms.map((t) => (t.id === term.id ? updated : t)),
    };
  }

  @action
  async setKeywordState(term, state) {
    try {
      const updated = await ajax(`${BASE}/terms/${term.id}`, {
        type: "PUT",
        data: { state },
      });
      this.#replaceTerm(term, { ...term, ...updated });
      await this.#reloadStatus();
    } catch (e) {
      popupAjaxError(e);
    }
  }

  @action
  deleteKeyword(term) {
    this.dialog.yesNoConfirm({
      message: i18n("sitemap_autolink.admin.delete_phrase_confirm", {
        phrase: term.phrase,
      }),
      didConfirm: async () => {
        try {
          await ajax(`${BASE}/terms/${term.id}`, { type: "DELETE" });
          this.termsData = {
            ...this.termsData,
            total: Math.max((this.termsData.total || 1) - 1, 0),
            terms: this.termsData.terms.filter((t) => t.id !== term.id),
          };
          await this.#reloadStatus();
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

  #currentEntry(entryId) {
    return this.entriesData.entries.find((e) => e.id === entryId);
  }

  #replaceEntryTerms(entryId, terms) {
    this.entriesData = {
      ...this.entriesData,
      entries: this.entriesData.entries.map((e) =>
        e.id === entryId ? { ...e, terms } : e
      ),
    };
  }

  @action
  async addPhrase(entry, event) {
    event.preventDefault();
    const input = event.target.querySelector("input");
    const phrase = input?.value?.trim();
    if (!phrase) {
      return;
    }
    try {
      const term = await ajax(`${BASE}/terms`, {
        type: "POST",
        data: { entry_id: entry.id, phrase },
      });
      const current = this.#currentEntry(entry.id);
      this.#replaceEntryTerms(entry.id, [...current.terms, term]);
      input.value = "";
    } catch (e) {
      popupAjaxError(e);
    }
  }

  @action
  async setEntryTermState(entry, term, state) {
    try {
      const updated = await ajax(`${BASE}/terms/${term.id}`, {
        type: "PUT",
        data: { state },
      });
      const current = this.#currentEntry(entry.id);
      this.#replaceEntryTerms(
        entry.id,
        current.terms.map((t) => (t.id === term.id ? updated : t))
      );
    } catch (e) {
      popupAjaxError(e);
    }
  }
}
