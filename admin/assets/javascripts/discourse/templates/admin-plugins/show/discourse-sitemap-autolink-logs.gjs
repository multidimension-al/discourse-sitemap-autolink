import { eq } from "truth-helpers";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

<template>
  <div class="sitemap-autolink-admin admin-detail">
    <DPageSubheader
      @titleLabel={{i18n "sitemap_autolink.admin.runs_title"}}
      @descriptionLabel={{i18n "sitemap_autolink.admin.logs_description"}}
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

    <section class="sitemap-autolink-admin__runs">
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
      {{else if @controller.runs}}
        <p class="sitemap-autolink-admin__empty">{{i18n
            "sitemap_autolink.admin.no_runs"
          }}</p>
      {{/if}}
    </section>
  </div>
</template>
