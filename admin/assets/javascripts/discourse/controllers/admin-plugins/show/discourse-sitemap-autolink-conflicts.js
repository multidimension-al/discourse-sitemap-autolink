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

export default class AdminPluginsShowSitemapAutolinkConflictsController extends Controller {
  @service dialog;

  @tracked collisions = null;
  @tracked overlaps = null;
  @tracked pluginDisabled = false;
  @tracked loadFailed = false;

  @tracked query = "";
  // Off by default: both reports now list only what changes a link, and
  // this is the opt-in that adds back the ones already settled.
  @tracked includeInactive = false;
  @tracked collisionPage = 0;
  @tracked overlapPage = 0;
  @tracked notice = null;

  // Always numbers: the summaries render before the first load
  // finishes, and i18n raises on an undefined interpolation value.
  get settledCollisions() {
    return this.collisions?.settled || 0;
  }

  get settledOverlaps() {
    return this.overlaps?.settled || 0;
  }

  get sameDestinationCount() {
    return this.overlaps?.same_destination || 0;
  }

  get collisionsDisplay() {
    return `${this.collisionPage + 1} / ${Math.max(this.collisions?.pages || 1, 1)}`;
  }

  get hasNextCollisions() {
    return this.collisionPage + 1 < (this.collisions?.pages || 1);
  }

  get overlapsDisplay() {
    return `${this.overlapPage + 1} / ${Math.max(this.overlaps?.pages || 1, 1)}`;
  }

  get hasNextOverlaps() {
    return this.overlapPage + 1 < (this.overlaps?.pages || 1);
  }

  @action
  async load() {
    await Promise.all([this.loadCollisions(), this.loadOverlaps()]);
  }

  #record(result) {
    if (result.pluginDisabled) {
      this.pluginDisabled = true;
    }
    if (result.failed) {
      this.loadFailed = true;
    }
    return result.data;
  }

  @action
  async loadCollisions() {
    const data = { page: this.collisionPage };
    if (this.query) {
      data.q = this.query;
    }
    if (this.includeInactive) {
      data.include_inactive = "true";
    }
    this.collisions = this.#record(await catalogGet("collisions", data));
  }

  @action
  async loadOverlaps() {
    const data = { page: this.overlapPage };
    if (this.query) {
      data.q = this.query;
    }
    if (this.includeInactive) {
      data.include_inactive = "true";
    }
    this.overlaps = this.#record(await catalogGet("overlaps", data));
  }

  @action
  updateQuery(event) {
    this.query = event.target.value;
  }

  @action
  search(event) {
    event?.preventDefault?.();
    this.collisionPage = 0;
    this.overlapPage = 0;
    this.load();
  }

  // The same question of both reports: show me the ones that are still
  // undecided, or every page that ever claimed the phrase.
  @action
  toggleIncludeInactive() {
    this.includeInactive = !this.includeInactive;
    this.collisionPage = 0;
    this.overlapPage = 0;
    this.load();
  }

  // Give the phrase to one page by disabling it on the others. Confirmed
  // because it edits keywords on pages the admin is not looking at.
  @action
  resolveCollision(collision, candidate) {
    this.dialog.yesNoConfirm({
      message: i18n("sitemap_autolink.admin.make_winner_confirm", {
        phrase: collision.phrase,
        title: candidate.title || candidate.url,
      }),
      didConfirm: async () => {
        try {
          const result = await ajax(`${BASE}/collisions/resolve`, {
            type: "POST",
            data: { phrase: collision.phrase, entry_id: candidate.entry_id },
          });
          // A resolve that would leave the phrase linking nowhere is
          // refused by the server, so anything that gets here worked.
          this.notice = i18n("sitemap_autolink.admin.make_winner_done", {
            count: result.disabled,
          });
          // Resolving can empty the page being viewed; without this the
          // pager keeps reading "4 / 1" over an empty section.
          this.collisionPage = 0;
          this.overlapPage = 0;
          await this.load();
        } catch (e) {
          popupAjaxError(e);
        }
      },
    });
  }

  @action
  prevCollisions() {
    if (this.collisionPage > 0) {
      this.collisionPage -= 1;
      this.loadCollisions();
    }
  }

  @action
  nextCollisions() {
    if (this.hasNextCollisions) {
      this.collisionPage += 1;
      this.loadCollisions();
    }
  }

  @action
  prevOverlaps() {
    if (this.overlapPage > 0) {
      this.overlapPage -= 1;
      this.loadOverlaps();
    }
  }

  @action
  nextOverlaps() {
    if (this.hasNextOverlaps) {
      this.overlapPage += 1;
      this.loadOverlaps();
    }
  }
}
