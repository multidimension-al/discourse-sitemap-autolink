# frozen_string_literal: true

# The staff-only JSON management API behind the admin catalog page.
RSpec.describe SitemapAutolinkAdminController do
  let(:base) { "/admin/plugins/discourse-sitemap-autolink" }

  fab!(:admin)
  fab!(:user)

  fab!(:entry) do
    SitemapAutolinkEntry.create!(
      url: "https://example.com/shop/widget-frame-kit",
      title: "Widget Frame Kit",
      content_type: "product",
      source: "sitemap",
      title_source: "page",
    )
  end

  before do
    SiteSetting.sitemap_autolink_enabled = true
    SitemapAutolink::Catalog.reset_cache!
  end

  describe "access" do
    it "is invisible to anonymous visitors and ordinary members" do
      get "#{base}/status"
      expect(response.status).to eq(404)

      sign_in(user)
      get "#{base}/status"
      expect(response.status).to eq(404)
    end

    it "answers 404 while the plugin is disabled" do
      SiteSetting.sitemap_autolink_enabled = false
      sign_in(admin)
      get "#{base}/status"
      expect(response.status).to eq(404)
    end
  end

  describe "#status" do
    it "summarizes the catalog and the compiled ruleset" do
      entry.terms.create!(phrase: "Widget Frame Kit", origin: :manual, state: :approved)
      entry.terms.create!(phrase: "Kit", origin: :generated, state: :pending_review)
      SitemapAutolink::Catalog.bump_version!
      sign_in(admin)

      get "#{base}/status"
      expect(response.status).to eq(200)
      json = response.parsed_body
      expect(json["enabled"]).to eq(true)
      expect(json["entries"]).to eq(1)
      expect(json["active_entries"]).to eq(1)
      expect(json["terms"]).to eq(2)
      expect(json["pending_terms"]).to eq(1)
      expect(json["active_rules"]).to eq(1)
      expect(json["entry_types"]).to eq(["product"])
    end
  end

  describe "#entries" do
    fab!(:wiki_entry) do
      SitemapAutolinkEntry.create!(
        url: "https://example.com/wiki/gasket-lore",
        title: "Gasket Lore",
        content_type: "wiki",
        source: "sitemap",
      )
    end

    before { sign_in(admin) }

    it "lists, searches and filters by type" do
      get "#{base}/entries"
      expect(response.parsed_body["total"]).to eq(2)
      expect(response.parsed_body["types"]).to contain_exactly("product", "wiki")

      get "#{base}/entries", params: { q: "gasket" }
      expect(response.parsed_body["entries"].map { |e| e["id"] }).to eq([wiki_entry.id])

      get "#{base}/entries", params: { type: "product" }
      expect(response.parsed_body["entries"].map { |e| e["id"] }).to eq([entry.id])
    end

    it "treats LIKE wildcards in the query as literal text" do
      get "#{base}/entries", params: { q: "%" }
      expect(response.parsed_body["total"]).to eq(0)
    end

    it "restricts to entries with phrases in a given state" do
      entry.terms.create!(phrase: "Kit", origin: :generated, state: :pending_review)

      get "#{base}/entries", params: { state: "pending_review" }
      expect(response.parsed_body["entries"].map { |e| e["id"] }).to eq([entry.id])
    end

    # The keyword an admin remembers is the way they look for the page
    # that owns it, so the search has to reach into phrases.
    it "finds a page by one of its keywords" do
      entry.terms.create!(phrase: "Foreman Widget", origin: :manual, state: :approved)

      get "#{base}/entries", params: { q: "foreman" }
      expect(response.parsed_body["entries"].map { |e| e["id"] }).to eq([entry.id])
    end

    it "counts phrases by state across the search, for the filters beside it" do
      entry.terms.create!(phrase: "Kit", origin: :generated, state: :pending_review)
      entry.terms.create!(phrase: "Widget Frame Kit", origin: :manual, state: :approved)

      get "#{base}/entries"
      expect(response.parsed_body["state_counts"]).to eq(
        "auto_active" => 0,
        "pending_review" => 1,
        "approved" => 1,
        "disabled" => 0,
      )
    end

    # A keyword two pages fight over is marked where it is read, not
    # only in a report the admin has to go looking for.
    it "marks a phrase another page also claims" do
      entry.terms.create!(phrase: "Widget Frame Kit", origin: :manual, state: :approved)
      entry.terms.create!(phrase: "Frame Kit", origin: :manual, state: :approved)
      wiki_entry.terms.create!(phrase: "Frame Kit", origin: :manual, state: :approved)

      get "#{base}/entries", params: { type: "product" }
      terms = response.parsed_body["entries"].first["terms"].index_by { |t| t["phrase"] }
      expect(terms["Frame Kit"]["duplicate"]).to eq(true)
      expect(terms["Widget Frame Kit"]["duplicate"]).to eq(false)
    end

    it "pages past the end without erroring" do
      get "#{base}/entries", params: { page: 5 }
      expect(response.status).to eq(200)
      expect(response.parsed_body["entries"]).to be_empty
    end
  end

  describe "entry mutation" do
    before { sign_in(admin) }

    it "normalizes the URL of a hand-created entry" do
      post "#{base}/entries",
           params: {
             url: " https://example.com/docs/setup/ ",
             title: "Setup",
             content_type: "docs",
           }

      expect(response.status).to eq(200)
      expect(response.parsed_body["url"]).to eq("https://example.com/docs/setup")
      expect(response.parsed_body["source"]).to eq("manual")
    end

    # The admin page sends "true"/"false" strings; a JSON client sends
    # real booleans. A bare `== "true"` would silently disable an entry
    # a JSON client asked to enable.
    it "accepts both string and JSON booleans when toggling an entry" do
      put "#{base}/entries/#{entry.id}", params: { enabled: "false" }
      expect(entry.reload.enabled).to eq(false)

      put "#{base}/entries/#{entry.id}", params: { enabled: true }, as: :json
      expect(entry.reload.enabled).to eq(true)
    end

    it "bumps the catalog version so every process recompiles" do
      expect { put "#{base}/entries/#{entry.id}", params: { enabled: "false" } }.to change {
        SitemapAutolink::Catalog.version
      }
    end
  end

  describe "#terms" do
    fab!(:wiki_entry) do
      SitemapAutolinkEntry.create!(
        url: "https://example.com/wiki/gasket-lore",
        title: "Gasket Lore",
        content_type: "wiki",
        source: "sitemap",
      )
    end

    before do
      entry.terms.create!(phrase: "Widget Frame Kit", origin: :manual, state: :approved)
      entry.terms.create!(
        phrase: "Kit",
        origin: :generated,
        state: :pending_review,
        review_reason: "generic_word",
      )
      wiki_entry.terms.create!(phrase: "Gasket Lore", origin: :generated, state: :auto_active)
      sign_in(admin)
    end

    it "lists every phrase with the destination it points at" do
      get "#{base}/terms"

      json = response.parsed_body
      expect(json["total"]).to eq(3)
      expect(json["terms"].map { |t| t["phrase"] }).to eq(["Gasket Lore", "Kit", "Widget Frame Kit"])
      expect(json["terms"].first).to include(
        "entry_url" => wiki_entry.url,
        "entry_title" => wiki_entry.title,
        "entry_active" => true,
      )
    end

    it "searches phrase text as well as destination title and URL" do
      get "#{base}/terms", params: { q: "gasket" }
      expect(response.parsed_body["terms"].map { |t| t["phrase"] }).to eq(["Gasket Lore"])

      get "#{base}/terms", params: { q: "frame-kit" }
      expect(response.parsed_body["terms"].map { |t| t["phrase"] }).to eq(["Widget Frame Kit"])
    end

    it "treats LIKE wildcards in the query as literal text" do
      get "#{base}/terms", params: { q: "%" }
      expect(response.parsed_body["total"]).to eq(0)
    end

    it "filters by state, type and origin" do
      get "#{base}/terms", params: { state: "pending_review" }
      expect(response.parsed_body["terms"].map { |t| t["phrase"] }).to eq(["Kit"])

      get "#{base}/terms", params: { type: "wiki" }
      expect(response.parsed_body["terms"].map { |t| t["phrase"] }).to eq(["Gasket Lore"])

      get "#{base}/terms", params: { origin: "manual" }
      expect(response.parsed_body["terms"].map { |t| t["phrase"] }).to eq(["Widget Frame Kit"])
    end

    it "rejects an unknown state filter instead of returning everything" do
      get "#{base}/terms", params: { state: "banana" }
      expect(response.status).to eq(400)
    end

    # The counts drive the state filters, so they must describe the rest
    # of the filter — not the state that is currently selected.
    it "counts states across the filter, ignoring the state filter itself" do
      get "#{base}/terms", params: { state: "pending_review" }

      json = response.parsed_body
      expect(json["total"]).to eq(1)
      expect(json["state_counts"]).to eq(
        "auto_active" => 1,
        "pending_review" => 1,
        "approved" => 1,
        "disabled" => 0,
      )
    end

    it "pages past the end without erroring" do
      get "#{base}/terms", params: { page: 5 }
      expect(response.status).to eq(200)
      expect(response.parsed_body["terms"]).to be_empty
    end

    it "flags phrases whose destination cannot link" do
      wiki_entry.update!(enabled: false)

      get "#{base}/terms", params: { type: "wiki" }
      expect(response.parsed_body["terms"].first["entry_active"]).to eq(false)
    end
  end

  describe "term mutation" do
    before { sign_in(admin) }

    it "adds a manual alias and stores its normalized form" do
      post "#{base}/terms", params: { entry_id: entry.id, phrase: "Foreman’s Widget" }

      expect(response.status).to eq(200)
      json = response.parsed_body
      expect(json["origin"]).to eq("manual")
      expect(json["state"]).to eq("approved")
      expect(json["normalized_phrase"]).to eq("foreman's widget")
    end

    it "rejects an unknown state as a bad request instead of a 500" do
      term = entry.terms.create!(phrase: "Widget Frame Kit", origin: :manual, state: :approved)

      put "#{base}/terms/#{term.id}", params: { state: "banana" }
      expect(response.status).to eq(400)
      expect(term.reload.state).to eq("approved")
    end

    it "clears a review queue in bulk" do
      first = entry.terms.create!(phrase: "Kit", origin: :generated, state: :pending_review)
      second = entry.terms.create!(phrase: "Kits", origin: :generated, state: :pending_review)

      put "#{base}/terms/bulk", params: { ids: [first.id, second.id], state: "approved" }
      expect(response.parsed_body["updated"]).to eq(2)
      expect([first.reload.state, second.reload.state]).to eq(%w[approved approved])
    end

    # A queue of thousands cannot be cleared 50 ids at a time, so bulk
    # also takes the filter the admin is looking at — and must respect
    # every part of it rather than treating "some filter" as "all rows".
    it "applies a bulk change to everything matching a filter" do
      queued = entry.terms.create!(phrase: "Kit", origin: :generated, state: :pending_review)
      untouched =
        entry.terms.create!(phrase: "Widget Frame Kit", origin: :manual, state: :approved)
      other_type =
        SitemapAutolinkEntry
          .create!(
            url: "https://example.com/wiki/kit-lore",
            title: "Kit Lore",
            content_type: "wiki",
            source: "sitemap",
          )
          .terms
          .create!(phrase: "Kit Lore", origin: :generated, state: :pending_review)

      put "#{base}/terms/bulk",
          params: {
            state: "disabled",
            filter: {
              state: "pending_review",
              type: "product",
            },
          }

      expect(response.parsed_body["updated"]).to eq(1)
      expect(queued.reload.state).to eq("disabled")
      expect(untouched.reload.state).to eq("approved")
      expect(other_type.reload.state).to eq("pending_review")
    end

    it "deletes a term" do
      term = entry.terms.create!(phrase: "Widget Frame Kit", origin: :manual, state: :approved)

      delete "#{base}/terms/#{term.id}"
      expect(response.status).to eq(200)
      expect(SitemapAutolinkTerm.find_by(id: term.id)).to be_nil
    end
  end

  # The review queue is the keyword list filtered to one state, so it
  # pages and searches like every other list on the page.
  describe "the review queue" do
    it "lists gated phrases with the entry they belong to" do
      term =
        entry.terms.create!(
          phrase: "Kit",
          origin: :generated,
          state: :pending_review,
          review_reason: "generic_word",
        )
      sign_in(admin)

      get "#{base}/terms", params: { state: "pending_review" }
      json = response.parsed_body
      expect(json["total"]).to eq(1)
      expect(json["terms"].first).to include(
        "id" => term.id,
        "review_reason" => "generic_word",
        "entry_url" => entry.url,
        "entry_title" => entry.title,
      )
    end
  end

  describe "#overlaps" do
    fab!(:short_entry) do
      SitemapAutolinkEntry.create!(
        url: "https://example.com/shop/frame-kit",
        title: "Frame Kit",
        content_type: "product",
        source: "sitemap",
      )
    end

    before do
      entry.terms.create!(phrase: "Widget Frame Kit", origin: :manual, state: :approved)
      short_entry.terms.create!(phrase: "Frame Kit", origin: :manual, state: :approved)
      SitemapAutolink::Catalog.bump_version!
      sign_in(admin)
    end

    it "reports the phrases a longer phrase swallows" do
      get "#{base}/overlaps"

      json = response.parsed_body
      expect(json["total"]).to eq(1)
      overlap = json["overlaps"].first
      expect(overlap["phrase"]).to eq("frame kit")
      expect(overlap["url"]).to eq(short_entry.url)
      expect(overlap["covered_by"].map { |c| c["phrase"] }).to eq(["widget frame kit"])
      expect(json["truncated"]).to eq(false)
    end

    it "does not report a phrase as covering itself" do
      short_entry.terms.first.update!(state: :disabled)
      SitemapAutolink::Catalog.bump_version!

      get "#{base}/overlaps"
      expect(response.parsed_body["overlaps"]).to be_empty
    end

    it "searches by phrase" do
      get "#{base}/overlaps", params: { q: "nothing-like-this" }
      expect(response.parsed_body["total"]).to eq(0)
    end
  end

  describe "#collisions" do
    fab!(:rival) do
      SitemapAutolinkEntry.create!(
        url: "https://example.com/wiki/widget-frame-kit",
        title: "Widget Frame Kit",
        content_type: "wiki",
        source: "sitemap",
      )
    end

    before do
      entry.terms.create!(phrase: "Widget Frame Kit", origin: :manual, state: :approved)
      rival.terms.create!(phrase: "Widget Frame Kit", origin: :manual, state: :approved)
      SitemapAutolink::Catalog.bump_version!
      sign_in(admin)
    end

    it "reports every destination claiming a phrase, and the winner" do
      get "#{base}/collisions"
      collision = response.parsed_body["collisions"].first
      expect(collision["phrase"]).to eq("widget frame kit")
      expect(collision["candidates"].map { |c| c["url"] }).to contain_exactly(
        entry.url,
        rival.url,
      )
      expect(collision["winner"]).to be_present
    end

    # Scoping DETECTION to active entries made the report disagree with
    # the catalog on screen: pages visibly claiming the same phrase were
    # reported as no conflict at all. Report it, and say which of them
    # is actually in the fight.
    it "still reports a phrase whose rival is disabled, marked not linking" do
      rival.update!(enabled: false)
      SitemapAutolink::Catalog.bump_version!

      get "#{base}/collisions"
      collision = response.parsed_body["collisions"].first
      expect(collision["phrase"]).to eq("widget frame kit")
      expect(collision["linking_candidates"]).to eq(1)
      expect(collision["candidates"].map { |c| [c["url"], c["linking"]] }).to contain_exactly(
        [entry.url, true],
        [rival.url, false],
      )
      expect(response.parsed_body["competing"]).to eq(0)
    end

    it "reports a phrase whose claimants are all awaiting review" do
      SitemapAutolinkTerm.update_all(state: SitemapAutolinkTerm.states[:pending_review])
      SitemapAutolink::Catalog.bump_version!

      get "#{base}/collisions"
      expect(response.parsed_body["collisions"].first["phrase"]).to eq("widget frame kit")
      expect(response.parsed_body["collisions"].first["linking_candidates"]).to eq(0)
    end

    it "narrows to live contests on request" do
      rival.update!(enabled: false)
      SitemapAutolink::Catalog.bump_version!

      get "#{base}/collisions", params: { only_competing: "true" }
      expect(response.parsed_body["collisions"]).to be_empty
    end

    it "pages and searches" do
      get "#{base}/collisions"
      expect(response.parsed_body).to include("total" => 1, "page" => 0, "pages" => 1)

      get "#{base}/collisions", params: { q: "gasket" }
      expect(response.parsed_body["collisions"]).to be_empty

      get "#{base}/collisions", params: { page: 3 }
      expect(response.parsed_body["collisions"]).to be_empty
    end
  end

  describe "#runs" do
    it "tells a live run apart from one whose process died" do
      SitemapAutolinkSyncRun.create!(
        started_at: 10.minutes.ago,
        updated_at: 10.minutes.ago,
        triggered_by: "schedule",
      )
      SitemapAutolinkSyncRun.create!(started_at: 5.seconds.ago, triggered_by: "manual")
      sign_in(admin)

      get "#{base}/runs"
      expect(response.parsed_body["runs"].map { |r| [r["triggered_by"], r["result"]] }).to eq(
        [%w[manual running], %w[schedule interrupted]],
      )
    end
  end

  describe "#sync" do
    before { sign_in(admin) }

    it "enqueues a run and lifts any lingering admin cancel" do
      SitemapAutolink::SitemapSync.request_cancel!

      expect_enqueued_with(job: :sitemap_autolink_sync, args: { triggered_by: "manual" }) do
        post "#{base}/sync"
      end
      expect(SitemapAutolink::SitemapSync.cancel_requested?).to eq(false)
    ensure
      SitemapAutolink::SitemapSync.clear_cancel!
    end

    it "reports a conflict instead of stacking a second run" do
      Discourse.redis.set(SitemapAutolink::SitemapSync::RUNNING_LOCK_KEY, "1")

      post "#{base}/sync"
      expect(response.status).to eq(409)
    ensure
      Discourse.redis.del(SitemapAutolink::SitemapSync::RUNNING_LOCK_KEY)
    end

    it "requests a cancel" do
      post "#{base}/sync/cancel"
      expect(response.status).to eq(200)
      expect(SitemapAutolink::SitemapSync.cancel_requested?).to eq(true)
    ensure
      SitemapAutolink::SitemapSync.clear_cancel!
    end
  end

  describe "#preview" do
    before { sign_in(admin) }

    it "refuses a dry run until sources are configured" do
      post "#{base}/preview"
      expect(response.status).to eq(422)
    end

    it "clamps the sample size a caller may ask for" do
      SiteSetting.sitemap_autolink_sources = "https://example.com/sitemap.xml,product"
      expect_any_instance_of(SitemapAutolink::SitemapSync).to receive(:preview).with(
        limit_per_source: 50,
      ).and_return({ sources: [], errors: [] })

      post "#{base}/preview", params: { limit: 5000 }
      expect(response.status).to eq(200)
    end
  end

  describe "#rebake" do
    before { sign_in(admin) }

    it "needs a phrase or an explicit all=true" do
      post "#{base}/rebake"
      expect(response.status).to eq(422)
    end

    it "enqueues the catalog-wide wave" do
      expect_enqueued_with(job: :sitemap_autolink_rebake_posts, args: { all_phrases: true }) do
        post "#{base}/rebake", params: { all: "true" }
      end
    end

    it "enqueues a single-phrase wave" do
      expect_enqueued_with(
        job: :sitemap_autolink_rebake_posts,
        args: {
          phrases: ["widget frame kit"],
        },
      ) { post "#{base}/rebake", params: { phrase: "widget frame kit" } }
    end
  end

  describe "#rebuild" do
    it "bumps the catalog version and returns the new one" do
      sign_in(admin)

      post "#{base}/rebuild"
      expect(response.status).to eq(200)
      expect(response.parsed_body["catalog_version"]).to eq(SitemapAutolink::Catalog.version)
    end
  end
end
