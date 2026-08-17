import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { eq, not } from "truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

const StateFilter = <template>
  <button
    type="button"
    class="btn btn-small sitemap-autolink-admin__state-filter
      {{if (eq @current @value) 'btn-primary'}}"
    data-state={{if @value @value "all"}}
    {{on "click" (fn @select @value)}}
  >{{@label}}
    <span
      class="sitemap-autolink-admin__filter-count"
    >{{@count}}</span></button>
</template>;

<template>
  <div class="sitemap-autolink-admin admin-detail">
    <DPageSubheader
      @titleLabel={{i18n "sitemap_autolink.admin.keywords_title"}}
      @descriptionLabel={{i18n "sitemap_autolink.admin.keywords_description"}}
    >
      <:actions as |actions|>
        <actions.Default
          @label="sitemap_autolink.admin.refresh"
          @isLoading={{@controller.loading}}
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

    <form
      class="sitemap-autolink-admin__search"
      {{on "submit" @controller.search}}
    >
      <input
        type="text"
        value={{@controller.query}}
        placeholder={{i18n "sitemap_autolink.admin.search_placeholder"}}
        {{on "input" @controller.updateQuery}}
      />
      <DButton
        @label="sitemap_autolink.admin.search"
        @action={{@controller.search}}
        class="btn-small sitemap-autolink-admin__search-btn"
      />
      <select
        class="sitemap-autolink-admin__type-filter"
        {{on "change" @controller.setTypeFilter}}
      >
        <option value="">{{i18n "sitemap_autolink.admin.all_types"}}</option>
        {{#each @controller.entryTypes as |type|}}
          <option value={{type}} selected={{eq type @controller.typeFilter}}>
            {{type}}
          </option>
        {{/each}}
      </select>
    </form>

    <div class="sitemap-autolink-admin__state-filters">
      <StateFilter
        @label={{i18n "sitemap_autolink.admin.state_all"}}
        @value=""
        @count={{@controller.totalPhrases}}
        @current={{@controller.stateFilter}}
        @select={{@controller.setStateFilter}}
      />
      <StateFilter
        @label={{i18n "sitemap_autolink.admin.state_pending_review"}}
        @value="pending_review"
        @count={{@controller.stateCounts.pending_review}}
        @current={{@controller.stateFilter}}
        @select={{@controller.setStateFilter}}
      />
      <StateFilter
        @label={{i18n "sitemap_autolink.admin.state_auto_active"}}
        @value="auto_active"
        @count={{@controller.stateCounts.auto_active}}
        @current={{@controller.stateFilter}}
        @select={{@controller.setStateFilter}}
      />
      <StateFilter
        @label={{i18n "sitemap_autolink.admin.state_approved"}}
        @value="approved"
        @count={{@controller.stateCounts.approved}}
        @current={{@controller.stateFilter}}
        @select={{@controller.setStateFilter}}
      />
      <StateFilter
        @label={{i18n "sitemap_autolink.admin.state_disabled"}}
        @value="disabled"
        @count={{@controller.stateCounts.disabled}}
        @current={{@controller.stateFilter}}
        @select={{@controller.setStateFilter}}
      />
    </div>

    <p class="sitemap-autolink-admin__bulk">
      <span class="sitemap-autolink-admin__result-count">
        {{i18n
          "sitemap_autolink.admin.result_summary"
          pages=@controller.matchingPages
          phrases=@controller.selectedPhrases
        }}
      </span>
      <DButton
        @label="sitemap_autolink.admin.approve_matching"
        @action={{fn @controller.bulkPhrases "approved"}}
        class="btn-small sitemap-autolink-admin__approve-all"
      />
      <DButton
        @label="sitemap_autolink.admin.disable_matching"
        @action={{fn @controller.bulkPhrases "disabled"}}
        class="btn-small btn-danger sitemap-autolink-admin__disable-all"
      />
    </p>

    {{#if @controller.data.entries.length}}
      {{! One card per destination, with every keyword that points at it.
      Title and type, then the URL, then the keywords, then the field to
      add one — each on its own line, because a title, a URL and a dozen
      phrases cannot share a row in a column this narrow. }}
      <div class="sitemap-autolink-admin__entry-list">
        {{#each @controller.data.entries as |entry|}}
          <article
            class="sitemap-autolink-admin__entry
              {{unless entry.enabled 'is-disabled'}}"
            data-entry-id={{entry.id}}
          >
            <header class="sitemap-autolink-admin__entry-header">
              <h4 class="sitemap-autolink-admin__entry-title">
                {{entry.title}}
                <span
                  class="sitemap-autolink-admin__pill"
                >{{entry.content_type}}</span>
                {{#if (eq entry.title_source "slug")}}
                  <span
                    class="sitemap-autolink-admin__pill --warning"
                    title={{i18n "sitemap_autolink.admin.slug_title_hint"}}
                  >{{i18n "sitemap_autolink.admin.slug_title"}}</span>
                {{/if}}
                {{#unless entry.enabled}}
                  <span class="sitemap-autolink-admin__pill --danger">{{i18n
                      "sitemap_autolink.admin.state_disabled"
                    }}</span>
                {{/unless}}
                {{#if entry.removed_from_source}}
                  <span class="sitemap-autolink-admin__pill --danger">{{i18n
                      "sitemap_autolink.admin.removed_from_source"
                    }}</span>
                {{/if}}
              </h4>
              <DButton
                @label={{if
                  entry.enabled
                  "sitemap_autolink.admin.disable"
                  "sitemap_autolink.admin.enable"
                }}
                @action={{fn @controller.toggleEntry entry}}
                class="btn-small sitemap-autolink-admin__toggle-entry"
              />
            </header>

            <a
              class="sitemap-autolink-admin__entry-url"
              href={{entry.url}}
              rel="noopener noreferrer"
              target="_blank"
            >{{entry.url}}</a>

            <div class="sitemap-autolink-admin__entry-terms">
              {{#each entry.terms as |term|}}
                <span
                  class="sitemap-autolink-admin__term"
                  data-term-id={{term.id}}
                  data-state={{term.state}}
                  title={{term.review_reason}}
                >
                  {{term.phrase}}
                  {{#if term.duplicate}}
                    <span
                      class="sitemap-autolink-admin__pill --warning"
                      title={{i18n "sitemap_autolink.admin.duplicate_hint"}}
                    >{{i18n "sitemap_autolink.admin.duplicate"}}</span>
                  {{/if}}
                  {{#if (eq term.state "pending_review")}}
                    <DButton
                      @icon="check"
                      @title="sitemap_autolink.admin.approve"
                      @action={{fn
                        @controller.setTermState
                        entry
                        term
                        "approved"
                      }}
                      class="btn-flat btn-small sitemap-autolink-admin__approve-term"
                    />
                  {{/if}}
                  {{#if (eq term.state "disabled")}}
                    <DButton
                      @icon="arrow-rotate-left"
                      @title="sitemap_autolink.admin.enable_phrase"
                      @action={{fn
                        @controller.setTermState
                        entry
                        term
                        "approved"
                      }}
                      class="btn-flat btn-small sitemap-autolink-admin__enable-term"
                    />
                  {{else}}
                    <DButton
                      @icon="xmark"
                      @title="sitemap_autolink.admin.disable_phrase"
                      @action={{fn
                        @controller.setTermState
                        entry
                        term
                        "disabled"
                      }}
                      class="btn-flat btn-small sitemap-autolink-admin__disable-term"
                    />
                  {{/if}}
                  {{#if (eq term.origin "manual")}}
                    <DButton
                      @icon="trash-can"
                      @title="sitemap_autolink.admin.delete_phrase"
                      @action={{fn @controller.deleteTerm entry term}}
                      class="btn-flat btn-small sitemap-autolink-admin__delete-term"
                    />
                  {{/if}}
                </span>
              {{else}}
                <span class="sitemap-autolink-admin__no-terms">{{i18n
                    "sitemap_autolink.admin.no_phrases"
                  }}</span>
              {{/each}}
            </div>

            <form
              class="sitemap-autolink-admin__add-phrase"
              {{on "submit" (fn @controller.addPhrase entry)}}
            >
              <input
                type="text"
                placeholder={{i18n
                  "sitemap_autolink.admin.add_phrase_placeholder"
                }}
              />
              <button type="submit" class="btn btn-small">
                {{i18n "sitemap_autolink.admin.add_phrase"}}
              </button>
            </form>
          </article>
        {{/each}}
      </div>

      <p class="sitemap-autolink-admin__pagination">
        <DButton
          @label="sitemap_autolink.admin.prev"
          @action={{@controller.prevPage}}
          @disabled={{not @controller.hasPrevPage}}
          class="btn-small sitemap-autolink-admin__prev"
        />
        <span>{{@controller.pageDisplay}}</span>
        <DButton
          @label="sitemap_autolink.admin.next"
          @action={{@controller.nextPage}}
          @disabled={{not @controller.hasNextPage}}
          class="btn-small sitemap-autolink-admin__next"
        />
      </p>
    {{else if @controller.data}}
      <p class="sitemap-autolink-admin__empty">{{i18n
          "sitemap_autolink.admin.no_entries"
        }}</p>
    {{/if}}
  </div>
</template>
