import { concat, fn, hash } from "@ember/helper";
import { on } from "@ember/modifier";
import { LinkTo } from "@ember/routing";
import { eq, not } from "truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

const ROUTE = "adminPlugins.show.discourse-sitemap-autolink-catalog";

const Tab = <template>
  <li>
    <LinkTo
      @route={{ROUTE}}
      @query={{hash tab=@tab}}
      class="sitemap-autolink-admin__tab"
      data-tab={{@tab}}
    >
      {{i18n (concat "sitemap_autolink.admin.tabs." @tab)}}
      {{#if @count}}<span
          class="sitemap-autolink-admin__tab-count"
        >{{@count}}</span>{{/if}}
    </LinkTo>
  </li>
</template>;

const Pagination = <template>
  <p class="sitemap-autolink-admin__pagination" ...attributes>
    <DButton
      @label="sitemap_autolink.admin.prev"
      @action={{@prev}}
      @disabled={{not @hasPrev}}
      class="btn-small sitemap-autolink-admin__prev"
    />
    <span>{{@display}}</span>
    <DButton
      @label="sitemap_autolink.admin.next"
      @action={{@next}}
      @disabled={{not @hasNext}}
      class="btn-small sitemap-autolink-admin__next"
    />
  </p>
</template>;

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

// The title IS the link: a full URL spelled out beside it is the widest
// thing on the page and says nothing the title does not. It stays one
// hover away as the tooltip, and searchable server-side.
const Destination = <template>
  <a href={{@url}} title={{@url}} rel="noopener noreferrer" target="_blank">{{if
      @title
      @title
      @url
    }}</a>
  {{#if @type}}
    <span class="sitemap-autolink-admin__pill">{{@type}}</span>
  {{/if}}
  {{#unless @active}}
    <span
      class="sitemap-autolink-admin__pill --danger"
      title={{i18n "sitemap_autolink.admin.destination_inactive_hint"}}
    >{{i18n "sitemap_autolink.admin.destination_inactive"}}</span>
  {{/unless}}
</template>;

const Overview = <template>
  <section class="sitemap-autolink-admin__status">
    <h3>{{i18n "sitemap_autolink.admin.status_title"}}</h3>
    {{#if @controller.status}}
      <p>
        {{i18n
          "sitemap_autolink.admin.status_summary"
          rules=@controller.status.active_rules
          entries=@controller.status.active_entries
          pending=@controller.status.pending_terms
        }}
      </p>
      {{#unless @controller.status.enabled}}
        <p class="sitemap-autolink-admin__warning">
          {{i18n "sitemap_autolink.admin.plugin_disabled"}}
        </p>
      {{/unless}}
      {{#unless @controller.status.sources_configured}}
        <p class="sitemap-autolink-admin__warning">
          {{i18n "sitemap_autolink.admin.no_sources"}}
        </p>
      {{/unless}}
      {{#if @controller.typesMismatch}}
        <p class="sitemap-autolink-admin__warning">
          {{i18n
            "sitemap_autolink.admin.no_rules_hint"
            entry_types=@controller.typesMismatch.entry_types
            allowed=@controller.typesMismatch.allowed
          }}
        </p>
      {{/if}}
    {{else if @controller.pluginDisabled}}
      <p class="sitemap-autolink-admin__warning">
        {{i18n "sitemap_autolink.admin.plugin_disabled"}}
      </p>
    {{else}}
      <p class="sitemap-autolink-admin__warning">
        {{i18n "sitemap_autolink.admin.load_failed"}}
      </p>
    {{/if}}
  </section>

  {{#if @controller.previewResult}}
    <section class="sitemap-autolink-admin__preview">
      <h3>{{i18n "sitemap_autolink.admin.preview_title"}}</h3>
      {{#each @controller.previewResult.errors as |error|}}
        <p class="sitemap-autolink-admin__warning">{{error}}</p>
      {{/each}}
      {{#each @controller.previewResult.sources as |source|}}
        <h4>{{source.sitemap}} ({{source.type}})</h4>
        <p>
          {{i18n
            "sitemap_autolink.admin.preview_source_summary"
            total=source.total_urls
            excluded=source.excluded_by_pattern
          }}
        </p>
        <table>
          <thead>
            <tr>
              <th>{{i18n "sitemap_autolink.admin.col_page"}}</th>
              <th>{{i18n "sitemap_autolink.admin.col_title"}}</th>
              <th>{{i18n "sitemap_autolink.admin.col_phrases"}}</th>
            </tr>
          </thead>
          <tbody>
            {{#each source.sampled as |page|}}
              <tr>
                <td><a
                    href={{page.url}}
                    rel="noopener noreferrer"
                    target="_blank"
                  >{{page.url}}</a></td>
                <td>{{page.title}}</td>
                <td>
                  {{#each page.phrases as |phrase|}}
                    <div>
                      "{{phrase.phrase}}"
                      {{#if phrase.reason}}
                        <em>({{phrase.state}}: {{phrase.reason}})</em>
                      {{else}}
                        <em>({{phrase.state}})</em>
                      {{/if}}
                    </div>
                  {{/each}}
                </td>
              </tr>
            {{/each}}
          </tbody>
        </table>
      {{/each}}
    </section>
  {{/if}}
</template>;

const Keywords = <template>
  <section class="sitemap-autolink-admin__keywords">
    <h3>
      {{i18n "sitemap_autolink.admin.keywords_title"}}
      ({{@controller.termsData.total}})
    </h3>
    <p class="sitemap-autolink-admin__hint">
      {{i18n "sitemap_autolink.admin.keywords_description"}}
    </p>

    <form
      class="sitemap-autolink-admin__keyword-search"
      {{on "submit" @controller.searchTerms}}
    >
      <input
        type="text"
        value={{@controller.termQuery}}
        placeholder={{i18n "sitemap_autolink.admin.keyword_search_placeholder"}}
        {{on "input" @controller.updateTermQuery}}
      />
      <DButton
        @label="sitemap_autolink.admin.search"
        @action={{@controller.searchTerms}}
        class="btn-small sitemap-autolink-admin__keyword-search-btn"
      />
      <select
        class="sitemap-autolink-admin__keyword-type-filter"
        {{on "change" @controller.setTermTypeFilter}}
      >
        <option value="">{{i18n "sitemap_autolink.admin.all_types"}}</option>
        {{#each @controller.entryTypes as |type|}}
          <option value={{type}} selected={{eq type @controller.termType}}>
            {{type}}
          </option>
        {{/each}}
      </select>
    </form>

    <div class="sitemap-autolink-admin__state-filters">
      <StateFilter
        @label={{i18n "sitemap_autolink.admin.state_all"}}
        @value=""
        @count={{@controller.termsTotal}}
        @current={{@controller.termState}}
        @select={{@controller.setTermStateFilter}}
      />
      <StateFilter
        @label={{i18n "sitemap_autolink.admin.state_pending_review"}}
        @value="pending_review"
        @count={{@controller.termStateCounts.pending_review}}
        @current={{@controller.termState}}
        @select={{@controller.setTermStateFilter}}
      />
      <StateFilter
        @label={{i18n "sitemap_autolink.admin.state_auto_active"}}
        @value="auto_active"
        @count={{@controller.termStateCounts.auto_active}}
        @current={{@controller.termState}}
        @select={{@controller.setTermStateFilter}}
      />
      <StateFilter
        @label={{i18n "sitemap_autolink.admin.state_approved"}}
        @value="approved"
        @count={{@controller.termStateCounts.approved}}
        @current={{@controller.termState}}
        @select={{@controller.setTermStateFilter}}
      />
      <StateFilter
        @label={{i18n "sitemap_autolink.admin.state_disabled"}}
        @value="disabled"
        @count={{@controller.termStateCounts.disabled}}
        @current={{@controller.termState}}
        @select={{@controller.setTermStateFilter}}
      />
    </div>

    {{#if @controller.termsData.terms.length}}
      <p class="sitemap-autolink-admin__bulk">
        <DButton
          @label="sitemap_autolink.admin.approve_matching"
          @action={{fn @controller.bulkTerms "approved"}}
          class="btn-small sitemap-autolink-admin__approve-all"
        />
        <DButton
          @label="sitemap_autolink.admin.disable_matching"
          @action={{fn @controller.bulkTerms "disabled"}}
          class="btn-small btn-danger sitemap-autolink-admin__disable-all"
        />
      </p>
      <table class="sitemap-autolink-admin__keyword-table">
        <thead>
          <tr>
            <th>{{i18n "sitemap_autolink.admin.col_phrase"}}</th>
            <th>{{i18n "sitemap_autolink.admin.col_destination"}}</th>
            <th>{{i18n "sitemap_autolink.admin.col_actions"}}</th>
          </tr>
        </thead>
        <tbody>
          {{#each @controller.termsData.terms as |term|}}
            <tr
              class="sitemap-autolink-admin__keyword"
              data-term-id={{term.id}}
              data-state={{term.state}}
            >
              <td>
                <span
                  class="sitemap-autolink-admin__phrase"
                >{{term.phrase}}</span>
                <span
                  class="sitemap-autolink-admin__pill --state-{{term.state}}"
                >{{term.state}}</span>
                {{#if (eq term.origin "manual")}}
                  <span class="sitemap-autolink-admin__pill">{{i18n
                      "sitemap_autolink.admin.origin_manual"
                    }}</span>
                {{/if}}
                {{#if term.review_reason}}
                  <span
                    class="sitemap-autolink-admin__reason"
                  >{{term.review_reason}}</span>
                {{/if}}
              </td>
              <td>
                <Destination
                  @url={{term.entry_url}}
                  @title={{term.entry_title}}
                  @type={{term.entry_type}}
                  @active={{term.entry_active}}
                />
              </td>
              <td>
                {{#unless (eq term.state "approved")}}
                  <DButton
                    @label="sitemap_autolink.admin.approve"
                    @action={{fn @controller.setKeywordState term "approved"}}
                    class="btn-small sitemap-autolink-admin__approve"
                  />
                {{/unless}}
                {{#unless (eq term.state "disabled")}}
                  <DButton
                    @label="sitemap_autolink.admin.disable"
                    @action={{fn @controller.setKeywordState term "disabled"}}
                    class="btn-small btn-danger sitemap-autolink-admin__disable"
                  />
                {{/unless}}
                {{#if (eq term.origin "manual")}}
                  <DButton
                    @icon="trash-can"
                    @title="sitemap_autolink.admin.delete_phrase"
                    @action={{fn @controller.deleteKeyword term}}
                    class="btn-flat btn-small sitemap-autolink-admin__delete"
                  />
                {{/if}}
              </td>
            </tr>
          {{/each}}
        </tbody>
      </table>
      <Pagination
        class="sitemap-autolink-admin__keyword-pagination"
        @display={{@controller.termsPageDisplay}}
        @hasPrev={{@controller.hasPrevTermsPage}}
        @hasNext={{@controller.hasNextTermsPage}}
        @prev={{@controller.prevTermsPage}}
        @next={{@controller.nextTermsPage}}
      />
    {{else}}
      <p class="sitemap-autolink-admin__empty">{{i18n
          "sitemap_autolink.admin.no_keywords"
        }}</p>
    {{/if}}
  </section>
</template>;

const Pages = <template>
  <section class="sitemap-autolink-admin__entries">
    <h3>
      {{i18n "sitemap_autolink.admin.entries_title"}}
      ({{@controller.entriesData.total}})
    </h3>
    <form
      class="sitemap-autolink-admin__search"
      {{on "submit" @controller.search}}
    >
      <input
        type="text"
        value={{@controller.searchQuery}}
        placeholder={{i18n "sitemap_autolink.admin.search_placeholder"}}
        {{on "input" @controller.updateSearchQuery}}
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
      <label class="sitemap-autolink-admin__pending-filter">
        <input
          type="checkbox"
          checked={{@controller.pendingOnly}}
          {{on "change" @controller.togglePendingOnly}}
        />
        {{i18n "sitemap_autolink.admin.with_pending_only"}}
      </label>
    </form>
    {{#if @controller.entriesData.entries.length}}
      {{! A page carries a long title, a long URL and any number of
      phrases. As table columns those fight each other for a width the
      admin area does not have, and every row wraps to a different
      height. Stacked instead — linked title and type, phrase chips,
      the add field, the toggle in the corner — each line is only as
      wide as it needs to be and every card looks the same. }}
      <div class="sitemap-autolink-admin__entry-list">
        {{#each @controller.entriesData.entries as |entry|}}
          <article
            class="sitemap-autolink-admin__entry
              {{unless entry.enabled 'is-disabled'}}"
            data-entry-id={{entry.id}}
          >
            <header class="sitemap-autolink-admin__entry-header">
              <h4 class="sitemap-autolink-admin__entry-title">
                <a
                  href={{entry.url}}
                  title={{entry.url}}
                  rel="noopener noreferrer"
                  target="_blank"
                >{{entry.title}}</a>
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

            <div class="sitemap-autolink-admin__entry-terms">
              {{#each entry.terms as |term|}}
                <span
                  class="sitemap-autolink-admin__term"
                  data-term-id={{term.id}}
                  data-state={{term.state}}
                >
                  {{term.phrase}}
                  {{#if (eq term.state "disabled")}}
                    <DButton
                      @icon="arrow-rotate-left"
                      @title="sitemap_autolink.admin.enable_phrase"
                      @action={{fn
                        @controller.setEntryTermState
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
                        @controller.setEntryTermState
                        entry
                        term
                        "disabled"
                      }}
                      class="btn-flat btn-small sitemap-autolink-admin__disable-term"
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
      <Pagination
        class="sitemap-autolink-admin__entry-pagination"
        @display={{@controller.pageDisplay}}
        @hasPrev={{@controller.hasPrevPage}}
        @hasNext={{@controller.hasNextPage}}
        @prev={{@controller.prevPage}}
        @next={{@controller.nextPage}}
      />
    {{else}}
      <p class="sitemap-autolink-admin__empty">{{i18n
          "sitemap_autolink.admin.no_entries"
        }}</p>
    {{/if}}
  </section>
</template>;

const Conflicts = <template>
  <form
    class="sitemap-autolink-admin__conflict-search"
    {{on "submit" @controller.searchConflicts}}
  >
    <input
      type="text"
      value={{@controller.conflictQuery}}
      placeholder={{i18n "sitemap_autolink.admin.conflict_search_placeholder"}}
      {{on "input" @controller.updateConflictQuery}}
    />
    <DButton
      @label="sitemap_autolink.admin.search"
      @action={{@controller.searchConflicts}}
      class="btn-small sitemap-autolink-admin__conflict-search-btn"
    />
  </form>

  <section class="sitemap-autolink-admin__collisions">
    <h3>
      {{i18n "sitemap_autolink.admin.collisions_title"}}
      ({{@controller.collisionsData.total}})
    </h3>
    <p class="sitemap-autolink-admin__hint">
      {{i18n "sitemap_autolink.admin.collisions_description"}}
    </p>
    {{#if @controller.collisionsData.collisions.length}}
      {{#each @controller.collisionsData.collisions as |collision|}}
        <div class="sitemap-autolink-admin__collision">
          <span
            class="sitemap-autolink-admin__phrase"
          >{{collision.phrase}}</span>
          {{#each collision.candidates as |candidate|}}
            <div
              class="sitemap-autolink-admin__candidate
                {{if candidate.winner 'is-winner'}}"
            >
              <Destination
                @url={{candidate.url}}
                @title={{candidate.title}}
                @type={{candidate.type}}
                @active={{true}}
              />
              {{#if candidate.winner}}
                <span class="sitemap-autolink-admin__pill --success">{{i18n
                    "sitemap_autolink.admin.collision_winner"
                  }}</span>
              {{/if}}
            </div>
          {{/each}}
        </div>
      {{/each}}
      <Pagination
        class="sitemap-autolink-admin__collision-pagination"
        @display={{@controller.collisionsPageDisplay}}
        @hasPrev={{@controller.hasPrevCollisionsPage}}
        @hasNext={{@controller.hasNextCollisionsPage}}
        @prev={{@controller.prevCollisionsPage}}
        @next={{@controller.nextCollisionsPage}}
      />
    {{else}}
      <p class="sitemap-autolink-admin__empty">{{i18n
          "sitemap_autolink.admin.no_collisions"
        }}</p>
    {{/if}}
  </section>

  <section class="sitemap-autolink-admin__overlaps">
    <h3>
      {{i18n "sitemap_autolink.admin.overlaps_title"}}
      ({{@controller.overlapsData.total}})
    </h3>
    <p class="sitemap-autolink-admin__hint">
      {{i18n "sitemap_autolink.admin.overlaps_description"}}
    </p>
    {{#if @controller.overlapsData.truncated}}
      <p class="sitemap-autolink-admin__warning">
        {{i18n "sitemap_autolink.admin.overlaps_truncated"}}
      </p>
    {{/if}}
    {{#if @controller.overlapsData.overlaps.length}}
      <table>
        <thead>
          <tr>
            <th>{{i18n "sitemap_autolink.admin.col_phrase"}}</th>
            <th>{{i18n "sitemap_autolink.admin.col_covered_by"}}</th>
          </tr>
        </thead>
        <tbody>
          {{#each @controller.overlapsData.overlaps as |overlap|}}
            <tr class="sitemap-autolink-admin__overlap">
              <td>
                <Destination
                  @url={{overlap.url}}
                  @title={{overlap.phrase}}
                  @type={{overlap.type}}
                  @active={{true}}
                />
              </td>
              <td>
                {{#each overlap.covered_by as |longer|}}
                  <div class="sitemap-autolink-admin__covering">
                    <Destination
                      @url={{longer.url}}
                      @title={{longer.phrase}}
                      @type={{longer.type}}
                      @active={{true}}
                    />
                  </div>
                {{/each}}
              </td>
            </tr>
          {{/each}}
        </tbody>
      </table>
      <Pagination
        class="sitemap-autolink-admin__overlap-pagination"
        @display={{@controller.overlapsPageDisplay}}
        @hasPrev={{@controller.hasPrevOverlapsPage}}
        @hasNext={{@controller.hasNextOverlapsPage}}
        @prev={{@controller.prevOverlapsPage}}
        @next={{@controller.nextOverlapsPage}}
      />
    {{else}}
      <p class="sitemap-autolink-admin__empty">{{i18n
          "sitemap_autolink.admin.no_overlaps"
        }}</p>
    {{/if}}
  </section>
</template>;

const Logs = <template>
  <section class="sitemap-autolink-admin__runs">
    <h3>{{i18n "sitemap_autolink.admin.runs_title"}}</h3>
    {{#if @controller.runs.length}}
      <table>
        <thead>
          <tr>
            <th>{{i18n "sitemap_autolink.admin.col_started"}}</th>
            <th>{{i18n "sitemap_autolink.admin.col_trigger"}}</th>
            <th>{{i18n "sitemap_autolink.admin.col_result"}}</th>
            <th>{{i18n "sitemap_autolink.admin.col_seen"}}</th>
            <th>{{i18n "sitemap_autolink.admin.col_excluded"}}</th>
            <th>{{i18n "sitemap_autolink.admin.col_added"}}</th>
            <th>{{i18n "sitemap_autolink.admin.col_removed"}}</th>
          </tr>
        </thead>
        <tbody>
          {{#each @controller.runs as |run|}}
            <tr>
              <td>{{run.started_at}}</td>
              <td>{{run.triggered_by}}</td>
              <td>
                {{#if (eq run.result "ok")}}
                  {{i18n "sitemap_autolink.admin.run_ok"}}
                {{else if (eq run.result "partial")}}
                  {{i18n "sitemap_autolink.admin.run_partial"}}
                {{else if (eq run.result "running")}}
                  {{i18n "sitemap_autolink.admin.run_running"}}
                {{else if (eq run.result "interrupted")}}
                  {{i18n "sitemap_autolink.admin.run_interrupted"}}
                {{else}}
                  {{i18n "sitemap_autolink.admin.run_failed"}}
                {{/if}}
              </td>
              <td>{{run.urls_seen}}</td>
              <td>{{run.urls_excluded}}</td>
              <td>{{run.entries_added}}</td>
              <td>{{run.entries_removed}}</td>
            </tr>
            {{#if run.error_details}}
              <tr>
                <td colspan="7">
                  <details>
                    <summary>{{i18n
                        "sitemap_autolink.admin.run_errors"
                      }}</summary>
                    <pre
                      class="sitemap-autolink-admin__errors"
                    >{{run.error_details}}</pre>
                  </details>
                </td>
              </tr>
            {{/if}}
          {{/each}}
        </tbody>
      </table>
    {{else}}
      <p class="sitemap-autolink-admin__empty">{{i18n
          "sitemap_autolink.admin.no_runs"
        }}</p>
    {{/if}}
  </section>
</template>;

<template>
  <div class="sitemap-autolink-admin admin-detail">
    <DPageSubheader
      @titleLabel={{i18n "sitemap_autolink.admin.catalog_title"}}
      @descriptionLabel={{i18n "sitemap_autolink.admin.catalog_description"}}
    >
      <:actions as |actions|>
        <actions.Primary
          @label="sitemap_autolink.admin.sync_now"
          @isLoading={{@controller.syncing}}
          @action={{@controller.syncNow}}
          class="sitemap-autolink-admin__sync"
        />
        <actions.Default
          @label="sitemap_autolink.admin.run_preview"
          @isLoading={{@controller.previewLoading}}
          @action={{@controller.runPreview}}
          class="sitemap-autolink-admin__preview-btn"
        />
        <actions.Default
          @label="sitemap_autolink.admin.rebake_all"
          @action={{@controller.rebakeAll}}
          class="sitemap-autolink-admin__rebake"
        />
        <actions.Default
          @label="sitemap_autolink.admin.refresh"
          @action={{@controller.refreshAll}}
          class="sitemap-autolink-admin__refresh"
        />
        {{#if @controller.syncRunning}}
          <actions.Default
            @label="sitemap_autolink.admin.cancel_run"
            @action={{@controller.cancelSync}}
            class="sitemap-autolink-admin__cancel"
          />
        {{/if}}
      </:actions>
    </DPageSubheader>

    {{#if @controller.notice}}
      <p class="sitemap-autolink-admin__notice">{{@controller.notice}}</p>
    {{/if}}

    <nav class="sitemap-autolink-admin__tabs">
      <ul class="nav nav-pills">
        <Tab @tab="overview" />
        <Tab @tab="keywords" @count={{@controller.pendingCount}} />
        <Tab @tab="pages" />
        <Tab @tab="conflicts" />
        <Tab @tab="logs" />
      </ul>
    </nav>

    {{#if (eq @controller.activeTab "keywords")}}
      <Keywords @controller={{@controller}} />
    {{else if (eq @controller.activeTab "pages")}}
      <Pages @controller={{@controller}} />
    {{else if (eq @controller.activeTab "conflicts")}}
      <Conflicts @controller={{@controller}} />
    {{else if (eq @controller.activeTab "logs")}}
      <Logs @controller={{@controller}} />
    {{else}}
      <Overview @controller={{@controller}} />
    {{/if}}
  </div>
</template>
