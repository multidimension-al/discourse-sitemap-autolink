import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { eq } from "truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

export default <template>
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
        />
        <actions.Default
          @label="sitemap_autolink.admin.run_preview"
          @isLoading={{@controller.previewLoading}}
          @action={{@controller.runPreview}}
        />
        <actions.Default
          @label="sitemap_autolink.admin.refresh"
          @action={{@controller.refreshAll}}
        />
      </:actions>
    </DPageSubheader>

    {{#if @controller.notice}}
      <p class="sitemap-autolink-admin__notice">{{@controller.notice}}</p>
    {{/if}}

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
                      <summary>{{i18n "sitemap_autolink.admin.run_errors"}}</summary>
                      <pre class="sitemap-autolink-admin__errors">{{run.error_details}}</pre>
                    </details>
                  </td>
                </tr>
              {{/if}}
            {{/each}}
          </tbody>
        </table>
      {{else}}
        <p>{{i18n "sitemap_autolink.admin.no_runs"}}</p>
      {{/if}}
    </section>

    <section class="sitemap-autolink-admin__pending">
      <h3>
        {{i18n "sitemap_autolink.admin.pending_title"}}
        ({{@controller.pendingTotal}})
      </h3>
      {{#if @controller.pendingTerms.length}}
        <p>
          <DButton
            @label="sitemap_autolink.admin.approve_all"
            @action={{fn @controller.bulkPending "approved"}}
            class="btn-small"
          />
          <DButton
            @label="sitemap_autolink.admin.disable_all"
            @action={{fn @controller.bulkPending "disabled"}}
            class="btn-small btn-danger"
          />
        </p>
        <table>
          <thead>
            <tr>
              <th>{{i18n "sitemap_autolink.admin.col_phrase"}}</th>
              <th>{{i18n "sitemap_autolink.admin.col_reason"}}</th>
              <th>{{i18n "sitemap_autolink.admin.col_destination"}}</th>
              <th>{{i18n "sitemap_autolink.admin.col_actions"}}</th>
            </tr>
          </thead>
          <tbody>
            {{#each @controller.pendingTerms as |term|}}
              <tr>
                <td>"{{term.phrase}}"</td>
                <td>{{term.review_reason}}</td>
                <td>
                  <a
                    href={{term.entry_url}}
                    rel="noopener noreferrer"
                    target="_blank"
                  >{{term.entry_title}}</a>
                </td>
                <td>
                  <DButton
                    @label="sitemap_autolink.admin.approve"
                    @action={{fn @controller.setTermState term "approved"}}
                    class="btn-small"
                  />
                  <DButton
                    @label="sitemap_autolink.admin.disable"
                    @action={{fn @controller.setTermState term "disabled"}}
                    class="btn-small btn-danger"
                  />
                </td>
              </tr>
            {{/each}}
          </tbody>
        </table>
      {{else}}
        <p>{{i18n "sitemap_autolink.admin.no_pending"}}</p>
      {{/if}}
    </section>

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
          class="btn-small"
        />
        <select {{on "change" @controller.setTypeFilter}}>
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
        <table>
          <thead>
            <tr>
              <th>{{i18n "sitemap_autolink.admin.col_title"}}</th>
              <th>{{i18n "sitemap_autolink.admin.col_type"}}</th>
              <th>{{i18n "sitemap_autolink.admin.col_url"}}</th>
              <th>{{i18n "sitemap_autolink.admin.col_phrases"}}</th>
              <th>{{i18n "sitemap_autolink.admin.col_actions"}}</th>
            </tr>
          </thead>
          <tbody>
            {{#each @controller.entriesData.entries as |entry|}}
              <tr>
                <td>
                  {{entry.title}}
                  {{#if (eq entry.title_source "slug")}}
                    <em
                      title={{i18n "sitemap_autolink.admin.slug_title_hint"}}
                    >({{i18n "sitemap_autolink.admin.slug_title"}})</em>
                  {{/if}}
                </td>
                <td>{{entry.content_type}}</td>
                <td><a
                    href={{entry.url}}
                    rel="noopener noreferrer"
                    target="_blank"
                  >{{entry.url}}</a></td>
                <td>
                  {{#each entry.terms as |term|}}
                    <div class="sitemap-autolink-admin__term">
                      "{{term.phrase}}"
                      <em>({{term.state}})</em>
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
                          class="btn-flat btn-small"
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
                          class="btn-flat btn-small"
                        />
                      {{/if}}
                    </div>
                  {{/each}}
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
                </td>
                <td>
                  <DButton
                    @label={{if
                      entry.enabled
                      "sitemap_autolink.admin.disable"
                      "sitemap_autolink.admin.enable"
                    }}
                    @action={{fn @controller.toggleEntry entry}}
                    class="btn-small"
                  />
                </td>
              </tr>
            {{/each}}
          </tbody>
        </table>
        <p class="sitemap-autolink-admin__pagination">
          <DButton
            @label="sitemap_autolink.admin.prev"
            @action={{@controller.prevPage}}
            @disabled={{unless @controller.hasPrevPage true}}
            class="btn-small"
          />
          <span>{{@controller.pageDisplay}}</span>
          <DButton
            @label="sitemap_autolink.admin.next"
            @action={{@controller.nextPage}}
            @disabled={{unless @controller.hasNextPage true}}
            class="btn-small"
          />
        </p>
      {{else}}
        <p>{{i18n "sitemap_autolink.admin.no_entries"}}</p>
      {{/if}}
    </section>

    <section class="sitemap-autolink-admin__collisions">
      <details>
        <summary>
          {{i18n "sitemap_autolink.admin.collisions_title"}}
          ({{@controller.collisions.length}})
        </summary>
        {{#each @controller.collisions as |collision|}}
          <div>
            "{{collision.phrase}}" →
            <strong>{{collision.winner}}</strong>
            {{#each collision.candidates as |candidate|}}
              <div class="sitemap-autolink-admin__candidate">
                {{candidate.url}} ({{candidate.type}})
              </div>
            {{/each}}
          </div>
        {{/each}}
        {{#unless @controller.collisions.length}}
          <p>{{i18n "sitemap_autolink.admin.no_collisions"}}</p>
        {{/unless}}
      </details>
    </section>
  </div>
</template>
