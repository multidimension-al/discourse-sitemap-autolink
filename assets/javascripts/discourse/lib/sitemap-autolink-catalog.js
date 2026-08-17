import { ajax } from "discourse/lib/ajax";

export const BASE = "/admin/plugins/discourse-sitemap-autolink";

// Every catalog page reads through here so they all report failure the
// same way.
//
// While sitemap_autolink_enabled is off, `requires_plugin` answers 404
// for every endpoint on these pages. That is a diagnosis, not an outage
// — and it is the one an admin opening the page for the first time most
// needs to read, so it must not be reported as "something failed, check
// your logs". Anything else is a real failure and must be shown as one:
// a page that quietly renders its empty state after a failed request
// says "you have no keywords", which is a lie.
export async function catalogGet(path, data) {
  try {
    return { data: await ajax(`${BASE}/${path}`, { data }) };
  } catch (error) {
    if (error?.jqXHR?.status === 404) {
      return { pluginDisabled: true };
    }
    return { failed: true };
  }
}
