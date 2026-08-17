import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { catalogGet } from "discourse/plugins/discourse-sitemap-autolink/discourse/lib/sitemap-autolink-catalog";

export default class AdminPluginsShowSitemapAutolinkConflictsController extends Controller {
  @tracked collisions = null;
  @tracked overlaps = null;
  @tracked pluginDisabled = false;
  @tracked loadFailed = false;

  @tracked query = "";
  @tracked onlyCompeting = false;
  @tracked collisionPage = 0;
  @tracked overlapPage = 0;

  // Always a number: the summary renders before the first load
  // finishes, and i18n raises on an undefined interpolation value.
  get competingCount() {
    return this.collisions?.competing || 0;
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
    if (this.onlyCompeting) {
      data.only_competing = "true";
    }
    this.collisions = this.#record(await catalogGet("collisions", data));
  }

  @action
  async loadOverlaps() {
    const data = { page: this.overlapPage };
    if (this.query) {
      data.q = this.query;
    }
    if (this.onlyCompeting) {
      data.only_competing = "true";
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

  // The same question of both reports: show me only what changes which
  // link a post actually gets.
  @action
  toggleOnlyCompeting() {
    this.onlyCompeting = !this.onlyCompeting;
    this.collisionPage = 0;
    this.overlapPage = 0;
    this.load();
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
