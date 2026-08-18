import { concat, fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { not } from "truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

// Why a candidate is out of the running. "not linking" alone left the
// admin to guess between a disabled keyword, a switched-off page, one
// that has dropped out of the sitemap and a site setting ruling it out —
// four different fixes. The server decides which it is; this only names
// it, so the label can never disagree with the flag beside it.
const NotLinking = <template>
  <span class="sitemap-autolink-admin__pill --danger">{{i18n
      (concat "sitemap_autolink.admin.reason_" @owner.reason)
    }}</span>
</template>;

const State = <template>
  <span class="sitemap-autolink-admin__pill --state-{{@owner.state}}">{{i18n
      (concat "sitemap_autolink.admin.state_" @owner.state)
    }}</span>
</template>;

const Owners = <template>
  {{#each @owners as |owner|}}
    <div class="sitemap-autolink-admin__owner">
      <a href={{owner.url}} rel="noopener noreferrer" target="_blank">{{if
          owner.title
          owner.title
          owner.url
        }}</a>
      <span class="sitemap-autolink-admin__pill">{{owner.type}}</span>
      {{#if owner.linking}}
        <State @owner={{owner}} />
      {{else}}
        <NotLinking @owner={{owner}} />
      {{/if}}
    </div>
  {{/each}}
</template>;

<template>
  <div class="sitemap-autolink-admin admin-detail">
    <DPageSubheader
      @titleLabel={{i18n "sitemap_autolink.admin.conflicts_title"}}
      @descriptionLabel={{i18n "sitemap_autolink.admin.conflicts_description"}}
    >
      <:actions as |actions|>
        <actions.Default
          @label="sitemap_autolink.admin.refresh"
          @action={{@controller.load}}
          class="sitemap-autolink-admin__refresh"
        />
      </:actions>
    </DPageSubheader>

    {{#if @controller.pluginDisabled}}
      <p class="sitemap-autolink-admin__warning">
        {{i18n "sitemap_autolink.admin.plugin_disabled"}}
      </p>
    {{else if @controller.loadFailed}}
      <p class="sitemap-autolink-admin__warning">
        {{i18n "sitemap_autolink.admin.load_failed"}}
      </p>
    {{/if}}

    {{#if @controller.notice}}
      <p class="sitemap-autolink-admin__notice">{{@controller.notice}}</p>
    {{/if}}

    <form
      class="sitemap-autolink-admin__search"
      {{on "submit" @controller.search}}
    >
      <input
        type="text"
        value={{@controller.query}}
        placeholder={{i18n
          "sitemap_autolink.admin.conflict_search_placeholder"
        }}
        {{on "input" @controller.updateQuery}}
      />
      <DButton
        @label="sitemap_autolink.admin.search"
        @action={{@controller.search}}
        class="btn-small sitemap-autolink-admin__search-btn"
      />
      <label class="sitemap-autolink-admin__competing-filter">
        <input
          type="checkbox"
          checked={{@controller.includeInactive}}
          {{on "change" @controller.toggleIncludeInactive}}
        />
        {{i18n "sitemap_autolink.admin.include_inactive"}}
      </label>
    </form>

    <section class="sitemap-autolink-admin__collisions">
      <h3>
        {{i18n "sitemap_autolink.admin.collisions_title"}}
        ({{@controller.collisions.total}})
      </h3>
      <p class="sitemap-autolink-admin__hint">
        {{i18n "sitemap_autolink.admin.collisions_summary"}}
      </p>
      {{#unless @controller.includeInactive}}
        {{#if @controller.settledCollisions}}
          <p class="sitemap-autolink-admin__hint">
            {{i18n
              "sitemap_autolink.admin.collisions_settled"
              count=@controller.settledCollisions
            }}
          </p>
        {{/if}}
      {{/unless}}
      {{#if @controller.collisions.collisions.length}}
        {{#each @controller.collisions.collisions as |collision|}}
          <div
            class="sitemap-autolink-admin__collision"
            data-phrase={{collision.phrase}}
          >
            <span
              class="sitemap-autolink-admin__phrase"
            >{{collision.phrase}}</span>
            <span class="sitemap-autolink-admin__pill">{{i18n
                "sitemap_autolink.admin.claimed_by"
                count=collision.candidates.length
              }}</span>
            {{#each collision.candidates as |candidate|}}
              <div
                class="sitemap-autolink-admin__candidate
                  {{if candidate.winner 'is-winner'}}
                  {{unless candidate.linking 'is-inactive'}}"
                data-entry-id={{candidate.entry_id}}
              >
                <a
                  href={{candidate.url}}
                  rel="noopener noreferrer"
                  target="_blank"
                >{{candidate.title}}</a>
                <span
                  class="sitemap-autolink-admin__pill"
                >{{candidate.type}}</span>
                {{#if candidate.linking}}
                  <State @owner={{candidate}} />
                {{else}}
                  <NotLinking @owner={{candidate}} />
                {{/if}}
                {{#if candidate.winner}}
                  <span class="sitemap-autolink-admin__pill --success">{{i18n
                      "sitemap_autolink.admin.collision_winner"
                    }}</span>
                {{else if candidate.can_win}}
                  <DButton
                    @label="sitemap_autolink.admin.make_winner"
                    @action={{fn
                      @controller.resolveCollision
                      collision
                      candidate
                    }}
                    class="btn-small sitemap-autolink-admin__make-winner"
                  />
                {{/if}}
              </div>
            {{/each}}
          </div>
        {{/each}}
        <p class="sitemap-autolink-admin__pagination">
          <DButton
            @label="sitemap_autolink.admin.prev"
            @action={{@controller.prevCollisions}}
            @disabled={{not @controller.collisionPage}}
            class="btn-small sitemap-autolink-admin__prev"
          />
          <span
            class="sitemap-autolink-admin__page-indicator"
          >{{@controller.collisionsDisplay}}</span>
          <DButton
            @label="sitemap_autolink.admin.next"
            @action={{@controller.nextCollisions}}
            @disabled={{not @controller.hasNextCollisions}}
            class="btn-small sitemap-autolink-admin__next"
          />
        </p>
      {{else if @controller.collisions}}
        <p class="sitemap-autolink-admin__empty">{{i18n
            "sitemap_autolink.admin.no_collisions"
          }}</p>
      {{/if}}
    </section>

    <section class="sitemap-autolink-admin__overlaps">
      <h3>
        {{i18n "sitemap_autolink.admin.overlaps_title"}}
        ({{@controller.overlaps.total}})
      </h3>
      <p class="sitemap-autolink-admin__hint">
        {{i18n "sitemap_autolink.admin.overlaps_description"}}
      </p>
      {{#if @controller.sameDestinationCount}}
        <p class="sitemap-autolink-admin__hint">
          {{i18n
            "sitemap_autolink.admin.overlaps_same_destination"
            count=@controller.sameDestinationCount
          }}
        </p>
      {{/if}}
      {{#unless @controller.includeInactive}}
        {{#if @controller.settledOverlaps}}
          <p class="sitemap-autolink-admin__hint">
            {{i18n
              "sitemap_autolink.admin.overlaps_settled"
              count=@controller.settledOverlaps
            }}
          </p>
        {{/if}}
      {{/unless}}
      {{#if @controller.overlaps.truncated}}
        <p class="sitemap-autolink-admin__warning">
          {{i18n "sitemap_autolink.admin.overlaps_truncated"}}
        </p>
      {{/if}}
      {{#if @controller.overlaps.overlaps.length}}
        {{#each @controller.overlaps.overlaps as |overlap|}}
          <div
            class="sitemap-autolink-admin__overlap"
            data-phrase={{overlap.phrase}}
          >
            <span
              class="sitemap-autolink-admin__phrase"
            >{{overlap.phrase}}</span>
            {{#unless overlap.linking}}
              <span class="sitemap-autolink-admin__pill --danger">{{i18n
                  "sitemap_autolink.admin.not_linking"
                }}</span>
            {{/unless}}
            <Owners @owners={{overlap.owners}} />
            {{#each overlap.covered_by as |longer|}}
              <div
                class="sitemap-autolink-admin__covering
                  {{unless longer.linking 'is-inactive'}}"
              >
                {{i18n "sitemap_autolink.admin.covered_by_phrase"}}
                <span
                  class="sitemap-autolink-admin__phrase"
                >{{longer.phrase}}</span>
                {{#unless longer.linking}}
                  <span class="sitemap-autolink-admin__pill --danger">{{i18n
                      "sitemap_autolink.admin.not_linking"
                    }}</span>
                {{/unless}}
                <Owners @owners={{longer.owners}} />
              </div>
            {{/each}}
          </div>
        {{/each}}
        <p class="sitemap-autolink-admin__pagination">
          <DButton
            @label="sitemap_autolink.admin.prev"
            @action={{@controller.prevOverlaps}}
            @disabled={{not @controller.overlapPage}}
            class="btn-small sitemap-autolink-admin__prev"
          />
          <span
            class="sitemap-autolink-admin__page-indicator"
          >{{@controller.overlapsDisplay}}</span>
          <DButton
            @label="sitemap_autolink.admin.next"
            @action={{@controller.nextOverlaps}}
            @disabled={{not @controller.hasNextOverlaps}}
            class="btn-small sitemap-autolink-admin__next"
          />
        </p>
      {{else if @controller.overlaps}}
        <p class="sitemap-autolink-admin__empty">{{i18n
            "sitemap_autolink.admin.no_overlaps"
          }}</p>
      {{/if}}
    </section>
  </div>
</template>
