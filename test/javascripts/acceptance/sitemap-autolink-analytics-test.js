import { click, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { cloneJSON } from "discourse/lib/object";
import postFixtures from "discourse/tests/fixtures/post";
import topicFixtures from "discourse/tests/fixtures/topic";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";

const TOPIC_ID = 130;
const POST_ID = 18;
const DESTINATION = "https://example.com/shop/widget-kit";

// Exactly what SitemapAutolink::LinkApplier writes into Post#cooked,
// next to an ordinary link that must be left alone.
const COOKED = `
  <p>I bought a
    <a class="sitemap-autolink sitemap-autolink-product"
       href="${DESTINATION}"
       data-sitemap-autolink="true"
       data-autolink-type="product"
       data-autolink-term="widget kit"
       data-autolink-id="11">widget kit</a>
    and read about it <a class="plain-link" href="https://example.com/blog">here</a>.</p>
`;

function topicWithAutolink() {
  const topic = cloneJSON(topicFixtures[`/t/${TOPIC_ID}.json`]);
  const post = cloneJSON(postFixtures[`/posts/${POST_ID}`]);

  post.topic_id = topic.id;
  post.cooked = COOKED;
  topic.post_stream = { posts: [post], stream: [post.id] };

  return topic;
}

// A synthetic click on an anchor still performs its default action, which
// would navigate the test runner away. Cancelling it in the capture phase
// (before the app boots, so this runs first) also stops core's click
// tracking from redirecting, without stopping propagation — the plugin's
// own capture-phase listener still sees every click.
function cancelNavigation(event) {
  event.preventDefault();
}

function trackingHooks(needs) {
  needs.hooks.beforeEach(function () {
    window.dataLayer = [];
    document.addEventListener("click", cancelNavigation, true);
  });

  needs.hooks.afterEach(function () {
    document.removeEventListener("click", cancelNavigation, true);
    delete window.dataLayer;
    delete window.gtag;
  });
}

acceptance("Sitemap Autolink | click analytics", function (needs) {
  needs.user();
  needs.settings({
    sitemap_autolink_enabled: true,
    sitemap_autolink_analytics_enabled: true,
  });

  trackingHooks(needs);

  needs.pretender((server, helper) => {
    server.get(`/t/${TOPIC_ID}.json`, () =>
      helper.response(topicWithAutolink())
    );
  });

  test("pushes a dataLayer event describing the clicked autolink", async function (assert) {
    await visit(`/t/-/${TOPIC_ID}`);

    assert
      .dom("a.sitemap-autolink")
      .exists("the server-generated link is rendered in the post");

    await click("a.sitemap-autolink");

    assert.strictEqual(window.dataLayer.length, 1, "one event was pushed");

    const event = window.dataLayer[0];
    assert.strictEqual(event.event, "internal_auto_link_click");
    assert.strictEqual(event.link_type, "product", "reports the entry type");
    assert.strictEqual(
      event.matched_term,
      "widget kit",
      "reports the phrase that matched"
    );
    assert.strictEqual(event.destination, DESTINATION);
    assert.strictEqual(
      event.post_id,
      String(POST_ID),
      "identifies the post the link was rendered in"
    );

    // The topic is read off the post's article element; the fallback that
    // parses it out of the URL cannot run here, because the test router
    // never touches window.location.
    const article = document.querySelector(
      `article[data-post-id="${POST_ID}"]`
    );
    assert.strictEqual(
      event.topic_id,
      article.getAttribute("data-topic-id"),
      "identifies the topic that post belongs to"
    );
  });

  test("prefers gtag when the page has it", async function (assert) {
    const events = [];
    window.gtag = (...args) => events.push(args);

    await visit(`/t/-/${TOPIC_ID}`);
    await click("a.sitemap-autolink");

    assert.strictEqual(events.length, 1, "gtag was called once");
    assert.strictEqual(events[0][0], "event");
    assert.strictEqual(events[0][1], "internal_auto_link_click");
    assert.strictEqual(events[0][2].destination, DESTINATION);
    assert.strictEqual(
      window.dataLayer.length,
      0,
      "the dataLayer fallback is not used as well"
    );
  });

  test("ignores links the plugin did not create", async function (assert) {
    await visit(`/t/-/${TOPIC_ID}`);
    // The claim under test is about the click, not about rendering the
    // page, and QUnit does not guarantee the order tests run in — so
    // start from empty rather than from whatever got here first.
    window.dataLayer.length = 0;
    await click("a.plain-link");

    assert.strictEqual(
      window.dataLayer.length,
      0,
      "ordinary links in a post are not tracked"
    );
  });
});

acceptance("Sitemap Autolink | click analytics disabled", function (needs) {
  needs.user();
  needs.settings({
    sitemap_autolink_enabled: true,
    sitemap_autolink_analytics_enabled: false,
  });

  trackingHooks(needs);

  needs.pretender((server, helper) => {
    server.get(`/t/${TOPIC_ID}.json`, () =>
      helper.response(topicWithAutolink())
    );
  });

  test("no click handler is installed", async function (assert) {
    await visit(`/t/-/${TOPIC_ID}`);
    await click("a.sitemap-autolink");

    assert.strictEqual(
      window.dataLayer.length,
      0,
      "nothing is tracked when sitemap_autolink_analytics_enabled is off"
    );
  });
});
