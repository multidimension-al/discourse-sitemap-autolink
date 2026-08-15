import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
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
          @action={{@controller.syncNow}}
        />
        <actions.Default
          @label="sitemap_autolink.admin.run_preview"
          @isLoading={{@controller.previewLoading}}
          @action={{@controller.runPreview}}
        />
      </:actions>
    </DPageSubheader>

    {{#if @controller.notice}}
      <p class="sitemap-autolink-admin__notice">{{@controller.notice}}</p>
    {{/if}}

    <section class="sitemap-autolink-admin__status">
      <h3>{{i18n "sitemap_autolink.admin.status_title"}}</h3>
      <p>
        {{i18n
          "sitemap_autolink.admin.status_summary"
          rules=@controller.model.status.active_rules
          entries=@controller.model.status.active_entries
          pending=@controller.model.status.pending_terms
        }}
      </p>
      {{#unless @controller.model.status.sources_configured}}
        <p class="sitemap-autolink-admin__warning">
          {{i18n "sitemap_autolink.admin.no_sources"}}
        </p>
      {{/unless}}
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
                  <td><a href={{page.url}} rel="noopener noreferrer" target="_blank">{{page.url}}</a></td>
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
      {{#if @controller.model.runs.length}}
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
              <th>{{i18n "sitemap_autolink.admin.col_errors"}}</th>
            </tr>
          </thead>
          <tbody>
            {{#each @controller.model.runs as |run|}}
              <tr>
                <td>{{run.started_at}}</td>
                <td>{{run.triggered_by}}</td>
                <td>
                  {{#if run.success}}
                    {{i18n "sitemap_autolink.admin.run_ok"}}
                  {{else}}
                    {{i18n "sitemap_autolink.admin.run_failed"}}
                  {{/if}}
                </td>
                <td>{{run.urls_seen}}</td>
                <td>{{run.urls_excluded}}</td>
                <td>{{run.entries_added}}</td>
                <td>{{run.entries_removed}}</td>
                <td>{{run.error_details}}</td>
              </tr>
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
        ({{@controller.pendingTerms.length}})
      </h3>
      {{#if @controller.pendingTerms.length}}
        <table>
          <thead>
            <tr>
              <th>{{i18n "sitemap_autolink.admin.col_phrase"}}</th>
              <th>{{i18n "sitemap_autolink.admin.col_reason"}}</th>
              <th>{{i18n "sitemap_autolink.admin.col_actions"}}</th>
            </tr>
          </thead>
          <tbody>
            {{#each @controller.pendingTerms as |term|}}
              <tr>
                <td>"{{term.phrase}}"</td>
                <td>{{term.review_reason}}</td>
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
      <form class="sitemap-autolink-admin__search" {{on "submit" @controller.search}}>
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
                <td>{{entry.title}}</td>
                <td>{{entry.content_type}}</td>
                <td><a href={{entry.url}} rel="noopener noreferrer" target="_blank">{{entry.url}}</a></td>
                <td>
                  {{#each entry.terms as |term|}}
                    <div>"{{term.phrase}}" <em>({{term.state}})</em></div>
                  {{/each}}
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
      {{else}}
        <p>{{i18n "sitemap_autolink.admin.no_entries"}}</p>
      {{/if}}
    </section>

    <section class="sitemap-autolink-admin__collisions">
      <h3>
        {{i18n "sitemap_autolink.admin.collisions_title"}}
        ({{@controller.model.collisions.length}})
      </h3>
      {{#each @controller.model.collisions as |collision|}}
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
      {{#unless @controller.model.collisions.length}}
        <p>{{i18n "sitemap_autolink.admin.no_collisions"}}</p>
      {{/unless}}
    </section>
  </div>
</template>
