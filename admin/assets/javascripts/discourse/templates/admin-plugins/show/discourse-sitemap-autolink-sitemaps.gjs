import { concat, fn } from "@ember/helper";
import { eq } from "truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

const UrlCount = <template>
  {{#if @sitemap.last_fetched_at}}
    <span class="sitemap-autolink-admin__sitemap-count">
      {{@sitemap.url_count}}{{if @sitemap.url_count_partial "+"}}
      {{i18n "sitemap_autolink.admin.sitemap_urls"}}
    </span>
  {{else}}
    <span class="sitemap-autolink-admin__sitemap-count --unknown">
      {{i18n "sitemap_autolink.admin.sitemap_not_read"}}
    </span>
  {{/if}}
</template>;

<template>
  <div class="sitemap-autolink-admin admin-detail">
    <DPageSubheader
      @titleLabel={{i18n "sitemap_autolink.admin.sitemaps_title"}}
      @descriptionLabel={{i18n "sitemap_autolink.admin.sitemaps_description"}}
    >
      <:actions as |actions|>
        <actions.Primary
          @label="sitemap_autolink.admin.discover"
          @isLoading={{@controller.discovering}}
          @action={{@controller.discover}}
          class="sitemap-autolink-admin__discover"
        />
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

    {{#if @controller.notice}}
      <p class="sitemap-autolink-admin__notice">{{@controller.notice}}</p>
    {{/if}}

    {{#if @controller.pendingCount}}
      <p class="sitemap-autolink-admin__warning">
        {{i18n
          "sitemap_autolink.admin.pending_sitemaps"
          count=@controller.pendingCount
        }}
      </p>
    {{/if}}

    {{#each @controller.undiscoveredSources as |url|}}
      <p class="sitemap-autolink-admin__warning">
        {{i18n "sitemap_autolink.admin.source_not_read" url=url}}
      </p>
    {{/each}}

    {{#if @controller.sitemaps.length}}
      <div class="sitemap-autolink-admin__sitemap-list">
        {{#each @controller.sitemaps as |sitemap|}}
          {{! Children are indented under the index that listed them, so
          the page reads as the tree it is rather than a flat list of
          URLs with no stated relationship. }}
          <article
            class="sitemap-autolink-admin__sitemap
              {{if sitemap.parent_url '--child'}}
              is-{{sitemap.status}}"
            data-sitemap-id={{sitemap.id}}
            data-status={{sitemap.status}}
          >
            <header class="sitemap-autolink-admin__sitemap-header">
              <a
                class="sitemap-autolink-admin__sitemap-url"
                href={{sitemap.url}}
                rel="noopener noreferrer"
                target="_blank"
              >{{sitemap.url}}</a>
              <span
                class="sitemap-autolink-admin__pill --status-{{sitemap.status}}"
              >{{i18n
                  (concat "sitemap_autolink.admin.sitemap_" sitemap.status)
                }}</span>
              {{#if (eq sitemap.kind "index")}}
                <span class="sitemap-autolink-admin__pill">{{i18n
                    "sitemap_autolink.admin.sitemap_index"
                  }}</span>
              {{/if}}
              <span
                class="sitemap-autolink-admin__pill"
              >{{sitemap.content_type}}</span>
            </header>

            <p class="sitemap-autolink-admin__sitemap-meta">
              <UrlCount @sitemap={{sitemap}} />
              {{#if sitemap.entries}}
                <span class="sitemap-autolink-admin__sitemap-count">
                  {{i18n
                    "sitemap_autolink.admin.sitemap_imported"
                    count=sitemap.entries
                    gone=sitemap.gone_entries
                  }}
                </span>
              {{/if}}
              {{#if sitemap.last_error}}
                <span
                  class="sitemap-autolink-admin__sitemap-error"
                >{{sitemap.last_error}}</span>
              {{/if}}
            </p>

            {{#unless (eq sitemap.kind "index")}}
              <div class="sitemap-autolink-admin__sitemap-actions">
                {{#if (eq sitemap.status "enabled")}}
                  {{#unless sitemap.configured}}
                    <DButton
                      @label="sitemap_autolink.admin.stop_importing"
                      @action={{fn @controller.stopImporting sitemap}}
                      class="btn-small sitemap-autolink-admin__stop-importing"
                    />
                    <DButton
                      @label="sitemap_autolink.admin.stop_and_purge"
                      @action={{fn @controller.stopAndPurge sitemap}}
                      class="btn-small btn-danger sitemap-autolink-admin__stop-purge"
                    />
                  {{/unless}}
                {{else}}
                  <DButton
                    @label="sitemap_autolink.admin.import_sitemap"
                    @action={{fn @controller.importSitemap sitemap}}
                    class="btn-small btn-primary sitemap-autolink-admin__import"
                  />
                  {{#if (eq sitemap.status "pending")}}
                    <DButton
                      @label="sitemap_autolink.admin.ignore_sitemap"
                      @action={{fn @controller.ignoreSitemap sitemap}}
                      class="btn-small sitemap-autolink-admin__ignore"
                    />
                  {{/if}}
                {{/if}}
              </div>
            {{/unless}}
          </article>
        {{/each}}
      </div>
    {{else if @controller.data}}
      <p class="sitemap-autolink-admin__empty">{{i18n
          "sitemap_autolink.admin.no_sitemaps"
        }}</p>
    {{/if}}
  </div>
</template>
