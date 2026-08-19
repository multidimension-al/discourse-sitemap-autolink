import { concat } from "@ember/helper";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

// One figure and what it means. `@tone` is only ever set on counts that
// are asking the admin for something — pages that fell out of a sitemap,
// keywords waiting on review — so the page reads at a glance.
const Stat = <template>
  <div
    class="sitemap-autolink-admin__stat {{if @tone (concat '--' @tone)}}"
    data-tone={{@tone}}
  >
    <span class="sitemap-autolink-admin__stat-value">{{@value}}</span>
    <span class="sitemap-autolink-admin__stat-label">{{@label}}</span>
  </div>
</template>;

<template>
  <div class="sitemap-autolink-admin admin-detail">
    <DPageSubheader
      @titleLabel={{i18n "sitemap_autolink.admin.overview_title"}}
      @descriptionLabel={{i18n "sitemap_autolink.admin.overview_description"}}
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
          @action={{@controller.load}}
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

    <section class="sitemap-autolink-admin__status">
      <h3>{{i18n "sitemap_autolink.admin.status_title"}}</h3>
      {{#if @controller.status}}
        {{#if @controller.stats}}
          <div class="sitemap-autolink-admin__stat-group" data-group="pages">
            <h4>{{i18n "sitemap_autolink.admin.stats_pages"}}</h4>
            <div class="sitemap-autolink-admin__stats">
              <Stat
                @value={{@controller.stats.pages.live}}
                @label={{i18n "sitemap_autolink.admin.stat_pages_live"}}
              />
              <Stat
                @value={{@controller.stats.pages.disabled}}
                @label={{i18n "sitemap_autolink.admin.stat_pages_disabled"}}
              />
              <Stat
                @value={{@controller.stats.pages.gone}}
                @label={{i18n "sitemap_autolink.admin.stat_pages_gone"}}
                @tone={{if @controller.stats.pages.gone "warn"}}
              />
              <Stat
                @value={{@controller.stats.pages.manual}}
                @label={{i18n "sitemap_autolink.admin.stat_pages_manual"}}
              />
              <Stat
                @value={{@controller.stats.pages.total}}
                @label={{i18n "sitemap_autolink.admin.stat_pages_total"}}
              />
            </div>
            {{#if @controller.typeBreakdown}}
              <p class="sitemap-autolink-admin__stat-breakdown">
                {{#each @controller.typeBreakdown as |row|}}
                  <span class="sitemap-autolink-admin__pill">{{row.type}}
                    {{row.count}}</span>
                {{/each}}
              </p>
            {{/if}}
          </div>

          <div class="sitemap-autolink-admin__stat-group" data-group="keywords">
            <h4>{{i18n "sitemap_autolink.admin.stats_keywords"}}</h4>
            <div class="sitemap-autolink-admin__stats">
              <Stat
                @value={{@controller.stats.keywords.auto_active}}
                @label={{i18n
                  "sitemap_autolink.admin.stat_keywords_auto_active"
                }}
              />
              <Stat
                @value={{@controller.stats.keywords.approved}}
                @label={{i18n "sitemap_autolink.admin.stat_keywords_approved"}}
              />
              <Stat
                @value={{@controller.stats.keywords.pending_review}}
                @label={{i18n "sitemap_autolink.admin.stat_keywords_pending"}}
                @tone={{if @controller.stats.keywords.pending_review "warn"}}
              />
              <Stat
                @value={{@controller.stats.keywords.disabled}}
                @label={{i18n "sitemap_autolink.admin.stat_keywords_disabled"}}
              />
              <Stat
                @value={{@controller.stats.keywords.manual}}
                @label={{i18n "sitemap_autolink.admin.stat_keywords_manual"}}
              />
              <Stat
                @value={{@controller.stats.keywords.total}}
                @label={{i18n "sitemap_autolink.admin.stat_keywords_total"}}
              />
            </div>
          </div>

          <div class="sitemap-autolink-admin__stat-group" data-group="linking">
            <h4>{{i18n "sitemap_autolink.admin.stats_linking"}}</h4>
            <div class="sitemap-autolink-admin__stats">
              <Stat
                @value={{@controller.stats.rules}}
                @label={{i18n "sitemap_autolink.admin.stat_rules"}}
              />
              <Stat
                @value={{@controller.stats.contested}}
                @label={{i18n "sitemap_autolink.admin.stat_contested"}}
                @tone={{if @controller.stats.contested "warn"}}
              />
            </div>
          </div>

          <div class="sitemap-autolink-admin__stat-group" data-group="sitemaps">
            <h4>{{i18n "sitemap_autolink.admin.stats_sitemaps"}}</h4>
            <div class="sitemap-autolink-admin__stats">
              <Stat
                @value={{@controller.stats.sitemaps.imported}}
                @label={{i18n "sitemap_autolink.admin.stat_sitemaps_imported"}}
              />
              <Stat
                @value={{@controller.stats.sitemaps.pending}}
                @label={{i18n "sitemap_autolink.admin.stat_sitemaps_pending"}}
                @tone={{if @controller.stats.sitemaps.pending "warn"}}
              />
              <Stat
                @value={{@controller.stats.sitemaps.ignored}}
                @label={{i18n "sitemap_autolink.admin.stat_sitemaps_ignored"}}
              />
              <Stat
                @value={{@controller.stats.sitemaps.indexes}}
                @label={{i18n "sitemap_autolink.admin.stat_sitemaps_indexes"}}
              />
            </div>
          </div>
        {{/if}}
        {{#unless @controller.status.enabled}}
          <p
            class="sitemap-autolink-admin__warning"
            data-warning="plugin-disabled"
          >
            {{i18n "sitemap_autolink.admin.plugin_disabled"}}
          </p>
        {{/unless}}
        {{#unless @controller.status.sources_configured}}
          <p class="sitemap-autolink-admin__warning" data-warning="no-sources">
            {{i18n "sitemap_autolink.admin.no_sources"}}
          </p>
        {{/unless}}
        {{#if @controller.status.pending_sitemaps}}
          <p
            class="sitemap-autolink-admin__warning"
            data-warning="pending-sitemaps"
          >
            {{i18n
              "sitemap_autolink.admin.pending_sitemaps_overview"
              count=@controller.status.pending_sitemaps
            }}
          </p>
        {{/if}}
        {{#if @controller.typesMismatch}}
          <p class="sitemap-autolink-admin__warning" data-warning="no-rules">
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
          {{#each source.sampled as |sample|}}
            <article class="sitemap-autolink-admin__entry">
              <h4 class="sitemap-autolink-admin__entry-title">
                {{sample.title}}
                <span
                  class="sitemap-autolink-admin__pill"
                >{{source.type}}</span>
              </h4>
              <a
                class="sitemap-autolink-admin__entry-url"
                href={{sample.url}}
                rel="noopener noreferrer"
                target="_blank"
              >{{sample.url}}</a>
              <div class="sitemap-autolink-admin__entry-terms">
                {{#each sample.phrases as |phrase|}}
                  <span
                    class="sitemap-autolink-admin__term"
                    data-state={{phrase.state}}
                    title={{phrase.reason}}
                  >{{phrase.phrase}}</span>
                {{/each}}
              </div>
            </article>
          {{/each}}
        {{/each}}
      </section>
    {{/if}}
  </div>
</template>
