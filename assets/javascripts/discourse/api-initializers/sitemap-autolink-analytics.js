import { apiInitializer } from "discourse/lib/api";

// Lightweight, optional GA4 click tracking for server-generated
// .sitemap-autolink links. Auto-linking works with or without this; if
// neither gtag nor dataLayer exists the handler is a no-op.
export default apiInitializer((api) => {
  const siteSettings = api.container.lookup("service:site-settings");
  if (!siteSettings.sitemap_autolink_analytics_enabled) {
    return;
  }

  const track = (event) => {
    const link = event.target?.closest?.("a.sitemap-autolink");
    if (!link) {
      return;
    }
    const params = {
      link_type: link.getAttribute("data-autolink-type") || "",
      matched_term: link.getAttribute("data-autolink-term") || "",
      destination: link.getAttribute("href") || "",
    };
    const article = link.closest("article[data-post-id]");
    if (article) {
      params.post_id = article.getAttribute("data-post-id");
      params.topic_id = article.getAttribute("data-topic-id");
    }
    if (!params.topic_id) {
      const match = window.location.pathname.match(/\/t\/[^/]+\/(\d+)/);
      if (match) {
        params.topic_id = match[1];
      }
    }
    try {
      if (typeof window.gtag === "function") {
        window.gtag("event", "internal_auto_link_click", params);
      } else if (Array.isArray(window.dataLayer)) {
        window.dataLayer.push({ event: "internal_auto_link_click", ...params });
      }
    } catch {
      // analytics must never interfere with navigation
    }
  };

  // Capture phase so we see the click before navigation handlers.
  document.addEventListener("click", track, true);
  document.addEventListener("auxclick", track, true);
});
