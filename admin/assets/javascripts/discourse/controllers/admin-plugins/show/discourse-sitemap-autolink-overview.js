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

const POLL_INTERVAL = 5000;
const MAX_POLLS = 36;

export default class AdminPluginsShowSitemapAutolinkOverviewController extends Controller {
  @service dialog;

  @tracked status = null;
  @tracked runs = [];
  @tracked pluginDisabled = false;
  @tracked loadFailed = false;
  @tracked notice = null;
  @tracked syncing = false;
  @tracked previewResult = null;
  @tracked previewLoading = false;

  #pollCount = 0;
  #pollTimer = null;

  // Controllers are singletons that outlive the page: without this a
  // sync poll scheduled here keeps firing (and re-rendering) long after
  // the admin has navigated away.
  willDestroy() {
    super.willDestroy(...arguments);
    clearTimeout(this.#pollTimer);
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

  @action
  async load() {
    const [status, runs] = await Promise.all([
      catalogGet("status"),
      catalogGet("runs"),
    ]);
    this.pluginDisabled = !!(status.pluginDisabled || runs.pluginDisabled);
    this.loadFailed = !!(status.failed || runs.failed);
    this.status = status.data || null;
    this.runs = runs.data?.runs || [];
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
        await this.load();
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
    return this.syncing || this.runs[0]?.result === "running";
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
          await ajax(`${BASE}/rebake`, { type: "POST", data: { all: "true" } });
          this.notice = i18n("sitemap_autolink.admin.rebake_all_started");
        } catch (e) {
          popupAjaxError(e);
        }
      },
    });
  }
}
