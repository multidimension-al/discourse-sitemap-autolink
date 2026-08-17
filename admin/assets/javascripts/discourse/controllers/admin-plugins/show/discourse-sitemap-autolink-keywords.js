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

// The catalog grouped by destination: one card per page, carrying every
// keyword that points at it. A phrase-per-row list answers "what is this
// keyword" — the question actually being asked is "what points at THIS
// page", which only a grouped view answers.
export default class AdminPluginsShowSitemapAutolinkKeywordsController extends Controller {
  @service dialog;

  @tracked data = null;
  @tracked pluginDisabled = false;
  @tracked loadFailed = false;
  @tracked loading = false;

  @tracked query = "";
  @tracked typeFilter = "";
  @tracked stateFilter = "";
  @tracked page = 0;

  get entryTypes() {
    return this.data?.types || [];
  }

  get stateCounts() {
    return this.data?.state_counts || {};
  }

  // Counts are for the search and type filter WITHOUT the state filter,
  // so "All" keeps meaning the same thing while a state chip is active.
  get totalPhrases() {
    return Object.values(this.stateCounts).reduce((sum, n) => sum + n, 0);
  }

  // Always a number: the summary line renders before the first load
  // finishes, and i18n raises on an undefined interpolation value.
  get matchingPages() {
    return this.data?.total || 0;
  }

  get selectedPhrases() {
    return this.stateFilter
      ? this.stateCounts[this.stateFilter] || 0
      : this.totalPhrases;
  }

  get pageDisplay() {
    return `${this.page + 1} / ${Math.max(this.data?.pages || 1, 1)}`;
  }

  get hasPrevPage() {
    return this.page > 0;
  }

  get hasNextPage() {
    return this.page + 1 < (this.data?.pages || 1);
  }

  params() {
    const data = { page: this.page };
    if (this.query) {
      data.q = this.query;
    }
    if (this.typeFilter) {
      data.type = this.typeFilter;
    }
    if (this.stateFilter) {
      data.state = this.stateFilter;
    }
    return data;
  }

  @action
  async load() {
    this.loading = true;
    const result = await catalogGet("entries", this.params());
    this.loading = false;
    this.pluginDisabled = !!result.pluginDisabled;
    this.loadFailed = !!result.failed;
    // On failure keep whatever was on screen: redrawing an empty list
    // would read as "nothing matches this filter".
    this.data = result.data || this.data;
  }

  @action
  updateQuery(event) {
    this.query = event.target.value;
  }

  @action
  search(event) {
    event?.preventDefault?.();
    this.page = 0;
    this.load();
  }

  @action
  setTypeFilter(event) {
    this.typeFilter = event.target.value;
    this.page = 0;
    this.load();
  }

  @action
  setStateFilter(state) {
    this.stateFilter = state;
    this.page = 0;
    this.load();
  }

  @action
  prevPage() {
    if (this.hasPrevPage) {
      this.page -= 1;
      this.load();
    }
  }

  @action
  nextPage() {
    if (this.hasNextPage) {
      this.page += 1;
      this.load();
    }
  }

  // Bulk over the whole current filter, not the cards on screen:
  // clearing a review queue of thousands 50 pages at a time is data
  // entry, not review. The confirmation names the exact count first.
  @action
  bulkPhrases(state) {
    const count = this.selectedPhrases;
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
                q: this.query,
                state: this.stateFilter,
                type: this.typeFilter,
              },
            },
          });
          await this.load();
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
      this.#replaceEntry(entry.id, updated);
    } catch (e) {
      popupAjaxError(e);
    }
  }

  #replaceEntry(entryId, updated) {
    this.data = {
      ...this.data,
      entries: this.data.entries.map((e) => (e.id === entryId ? updated : e)),
    };
  }

  #replaceTerms(entryId, terms) {
    this.data = {
      ...this.data,
      entries: this.data.entries.map((e) =>
        e.id === entryId ? { ...e, terms } : e
      ),
    };
  }

  #currentEntry(entryId) {
    return this.data.entries.find((e) => e.id === entryId);
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
      this.#replaceTerms(entry.id, [
        ...this.#currentEntry(entry.id).terms,
        term,
      ]);
      input.value = "";
    } catch (e) {
      popupAjaxError(e);
    }
  }

  @action
  async setTermState(entry, term, state) {
    try {
      const updated = await ajax(`${BASE}/terms/${term.id}`, {
        type: "PUT",
        data: { state },
      });
      this.#replaceTerms(
        entry.id,
        this.#currentEntry(entry.id).terms.map((t) =>
          t.id === term.id ? { ...t, ...updated } : t
        )
      );
    } catch (e) {
      popupAjaxError(e);
    }
  }

  @action
  deleteTerm(entry, term) {
    this.dialog.yesNoConfirm({
      message: i18n("sitemap_autolink.admin.delete_phrase_confirm", {
        phrase: term.phrase,
      }),
      didConfirm: async () => {
        try {
          await ajax(`${BASE}/terms/${term.id}`, { type: "DELETE" });
          this.#replaceTerms(
            entry.id,
            this.#currentEntry(entry.id).terms.filter((t) => t.id !== term.id)
          );
        } catch (e) {
          popupAjaxError(e);
        }
      },
    });
  }
}
