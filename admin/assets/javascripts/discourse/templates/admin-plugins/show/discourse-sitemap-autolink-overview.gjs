import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

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
