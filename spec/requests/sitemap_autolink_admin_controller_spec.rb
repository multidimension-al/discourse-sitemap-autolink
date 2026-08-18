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

  # Record that a sitemap lists an entry, creating the sitemap if the
  # test has not named it before.
  def list_in(entry, sitemap_url, status: "enabled", **attrs)
    sitemap =
      SitemapAutolinkSitemap.find_or_create_by!(url: sitemap_url) do |record|
        record.status = status
        record.kind = "urlset"
        record.content_type = entry&.content_type || "content"
        record.assign_attributes(attrs)
      end
    SitemapAutolinkEntrySitemap.create!(entry_id: entry.id, sitemap_id: sitemap.id) if entry
    sitemap
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

    # The write endpoints are what an access regression would actually
    # cost, so they are asserted rather than assumed from the read one.
    it "closes the write endpoints to anyone who is not staff" do
      entry.terms.create!(phrase: "Widget Frame Kit", origin: :manual, state: :approved)

      post "#{base}/collisions/resolve", params: { phrase: "Widget Frame Kit", entry_id: entry.id }
      expect(response.status).to eq(404)

      sign_in(user)
      post "#{base}/collisions/resolve", params: { phrase: "Widget Frame Kit", entry_id: entry.id }
      expect(response.status).to eq(404)

      expect(entry.terms.first.reload.state).to eq("approved")
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

    it "reports the figures the overview draws" do
      entry.terms.create!(phrase: "Widget Frame Kit", origin: :manual, state: :approved)
      entry.terms.create!(phrase: "Kit", origin: :generated, state: :pending_review)
      gone =
        SitemapAutolinkEntry.create!(
          url: "https://example.com/shop/discontinued",
          title: "Discontinued Widget",
          content_type: "product",
          source: "sitemap",
          removed_from_source: true,
        )
      list_in(gone, "https://example.com/sitemap-shop.xml")
      list_in(nil, "https://example.com/sitemap-wiki.xml", status: "pending")
      list_in(nil, "https://example.com/sitemap.xml", kind: "index")
      SitemapAutolink::Catalog.bump_version!
      sign_in(admin)

      get "#{base}/status"
      stats = response.parsed_body["stats"]
      expect(stats["pages"]).to include("total" => 2, "live" => 1, "gone" => 1, "disabled" => 0)
      expect(stats["pages"]["by_type"]).to eq({ "product" => 1 })
      expect(stats["keywords"]).to include(
        "total" => 2,
        "auto_active" => 0,
        "approved" => 1,
        "pending_review" => 1,
        "disabled" => 0,
        "manual" => 1,
      )
      # The four states account for every keyword — a group that does
      # not add up cannot be read.
      states = stats["keywords"].values_at("auto_active", "approved", "pending_review", "disabled")
      expect(states.sum).to eq(stats["keywords"]["total"])
      expect(stats["pages"]["manual"]).to eq(0)
      expect(stats["rules"]).to eq(1)
      expect(stats["contested"]).to eq(0)
      # The index is counted as an index, not as something importing:
      # it imports nothing, which is what the Sitemaps page says too.
      expect(stats["sitemaps"]).to include(
        "imported" => 1,
        "pending" => 1,
        "ignored" => 0,
        "indexes" => 1,
      )
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

    # A site can feed the plugin several sitemaps, and "show me only the
    # one I just changed" is not answerable by searching text.
    it "filters by the sitemap an entry came out of" do
      list_in(entry, "https://example.com/sitemap-products.xml")
      list_in(wiki_entry, "https://example.com/sitemap-wiki.xml")

      get "#{base}/entries"
      expect(response.parsed_body["sitemaps"]).to eq(
        ["https://example.com/sitemap-products.xml", "https://example.com/sitemap-wiki.xml"],
      )

      get "#{base}/entries", params: { sitemap: "https://example.com/sitemap-wiki.xml" }
      expect(response.parsed_body["entries"].map { |e| e["id"] }).to eq([wiki_entry.id])
    end

    # The same URL is routinely listed in more than one sitemap; it has
    # to be findable under either of them, and to say so on its card.
    it "finds a page listed in two sitemaps under both of them" do
      list_in(entry, "https://example.com/sitemap-products.xml")
      list_in(entry, "https://example.com/sitemap-featured.xml")
      list_in(wiki_entry, "https://example.com/sitemap-wiki.xml")

      get "#{base}/entries", params: { sitemap: "https://example.com/sitemap-featured.xml" }
      found = response.parsed_body["entries"]
      expect(found.map { |e| e["id"] }).to eq([entry.id])
      expect(found.first["sitemaps"]).to eq(
        ["https://example.com/sitemap-featured.xml", "https://example.com/sitemap-products.xml"],
      )

      get "#{base}/entries", params: { sitemap: "https://example.com/sitemap-products.xml" }
      expect(response.parsed_body["entries"].map { |e| e["id"] }).to eq([entry.id])
    end

    it "keeps a bulk change inside the sitemap filter" do
      list_in(entry, "https://example.com/sitemap-products.xml")
      entry.terms.create!(phrase: "Widget Frame Kit", origin: :generated, state: :auto_active)
      list_in(wiki_entry, "https://example.com/sitemap-wiki.xml")
      wiki_entry.terms.create!(phrase: "Gasket Lore", origin: :generated, state: :auto_active)

      put "#{base}/terms/bulk",
          params: {
            state: "disabled",
            filter: {
              sitemap: "https://example.com/sitemap-wiki.xml",
            },
          }

      expect(response.parsed_body["updated"]).to eq(1)
      expect(wiki_entry.terms.first.reload.state).to eq("disabled")
      expect(entry.terms.first.reload.state).to eq("auto_active")
    end

    # A keyword's state says it got through review. Whether it LINKS also
    # depends on its page being live, and reporting only the state calls
    # a page that was filtered out of the sitemap "auto-active".
    describe "pages that cannot link" do
      before do
        entry.terms.create!(phrase: "Widget Frame Kit", origin: :generated, state: :auto_active)
        wiki_entry.terms.create!(phrase: "Gasket Lore", origin: :generated, state: :auto_active)
        wiki_entry.update!(removed_from_source: true)
      end

      it "counts a keyword as auto-active but not as linking" do
        get "#{base}/entries"

        json = response.parsed_body
        expect(json["state_counts"]["auto_active"]).to eq(2)
        expect(json["linking_count"]).to eq(1)
      end

      # Both directions: `merge` would replace the page filter's own
      # condition rather than anding it, and answer each of these with
      # the other one's count.
      it "filters to the pages that dropped out of the sitemap" do
        get "#{base}/entries", params: { page_state: "removed" }
        expect(response.parsed_body["entries"].map { |e| e["id"] }).to eq([wiki_entry.id])
        expect(response.parsed_body["linking_count"]).to eq(0)

        get "#{base}/entries", params: { page_state: "live" }
        expect(response.parsed_body["entries"].map { |e| e["id"] }).to eq([entry.id])
        expect(response.parsed_body["linking_count"]).to eq(1)
      end

      it "filters to live pages, and to disabled ones" do
        entry.update!(enabled: false)

        get "#{base}/entries", params: { page_state: "live" }
        expect(response.parsed_body["entries"]).to be_empty

        get "#{base}/entries", params: { page_state: "disabled" }
        expect(response.parsed_body["entries"].map { |e| e["id"] }).to eq([entry.id])
      end

      # The count beside a bulk button has to describe what the button
      # would touch, so the page filter has to reach the keyword scope.
      it "keeps a bulk change inside the page filter" do
        put "#{base}/terms/bulk",
            params: {
              state: "disabled",
              filter: {
                page_state: "removed",
              },
            }

        expect(response.parsed_body["updated"]).to eq(1)
        expect(wiki_entry.terms.first.reload.state).to eq("disabled")
        expect(entry.terms.first.reload.state).to eq("auto_active")
      end
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

      # A URL match is a match on the page, so it returns every keyword
      # that page owns — not only the one that reads like the URL.
      get "#{base}/terms", params: { q: "frame-kit" }
      expect(response.parsed_body["terms"].map { |t| t["phrase"] }).to eq(
        ["Kit", "Widget Frame Kit"],
      )
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

    it "reports the keywords a longer keyword swallows" do
      get "#{base}/overlaps"

      json = response.parsed_body
      expect(json["total"]).to eq(1)
      overlap = json["overlaps"].first
      expect(overlap["phrase"]).to eq("frame kit")
      expect(overlap["linking"]).to eq(true)
      expect(overlap["owners"].map { |o| o["url"] }).to eq([short_entry.url])
      expect(overlap["covered_by"].map { |c| c["phrase"] }).to eq(["widget frame kit"])
      expect(json["truncated"]).to eq(false)
    end

    it "does not report a keyword as covering itself" do
      short_entry.terms.first.destroy!

      get "#{base}/overlaps"
      expect(response.parsed_body["overlaps"]).to be_empty
    end

    # A page title carrying two other pages' names swallows both of
    # them, and each has to be reported against the whole title.
    it "reports every keyword a long title contains" do
      ["Acme Widget Kit Gasket Set", "Widget Kit", "Gasket Set"].each_with_index do |phrase, i|
        SitemapAutolinkEntry
          .create!(
            url: "https://example.com/gb/#{i}",
            title: phrase,
            content_type: "product",
            source: "sitemap",
          )
          .terms
          .create!(phrase: phrase, origin: :manual, state: :approved)
      end

      get "#{base}/overlaps", params: { q: "widget kit" }
      overlap = response.parsed_body["overlaps"].find { |o| o["phrase"] == "widget kit" }
      expect(overlap["covered_by"].map { |c| c["phrase"] }).to eq(
        ["acme widget kit gasket set"],
      )

      get "#{base}/overlaps", params: { q: "gasket" }
      overlap = response.parsed_body["overlaps"].find { |o| o["phrase"] == "gasket set" }
      expect(overlap["covered_by"].map { |c| c["phrase"] }).to eq(
        ["acme widget kit gasket set"],
      )
    end

    # Sourcing the report from the compiled ruleset hid the overlaps
    # most worth seeing: a keyword still awaiting review had none.
    it "reports a keyword awaiting review, marked not linking" do
      short_entry.terms.first.update!(state: :pending_review)
      SitemapAutolink::Catalog.bump_version!

      get "#{base}/overlaps", params: { include_inactive: "true" }
      overlap = response.parsed_body["overlaps"].first
      expect(overlap["phrase"]).to eq("frame kit")
      expect(overlap["linking"]).to eq(false)
      expect(overlap["owners"].first["reason"]).to eq("keyword_pending")
    end

    it "leaves out a pair one side of which does not link" do
      short_entry.terms.first.update!(state: :pending_review)
      SitemapAutolink::Catalog.bump_version!

      get "#{base}/overlaps"
      expect(response.parsed_body["overlaps"]).to be_empty
      expect(response.parsed_body["settled"]).to eq(1)
    end

    # The complaint this rule exists for: a page titled "Deluxe Widget
    # Kit" generates "widget kit" as well, so the catalog is full of
    # pairs where both keywords lead to the SAME page. Whichever one
    # fires, the reader lands in the same place — there is nothing to
    # decide, and at catalog scale these drowned out the real overlaps.
    it "does not report a keyword swallowed by a longer one on the same page" do
      SitemapAutolinkTerm.delete_all
      same =
        SitemapAutolinkEntry.create!(
          url: "https://example.com/shop/deluxe-widget-kit",
          title: "Deluxe Widget Kit",
          content_type: "product",
          source: "sitemap",
        )
      same.terms.create!(phrase: "Deluxe Widget Kit", origin: :generated, state: :auto_active)
      same.terms.create!(phrase: "Widget Kit", origin: :generated, state: :auto_active)
      SitemapAutolink::Catalog.bump_version!

      get "#{base}/overlaps"
      expect(response.parsed_body["overlaps"]).to be_empty
      expect(response.parsed_body["same_destination"]).to eq(1)
    end

    # ...but the same containment between two DIFFERENT pages is the
    # decision the report is for.
    it "reports the same containment when the two keywords lead to different pages" do
      SitemapAutolinkTerm.delete_all
      entry.terms.create!(phrase: "Widget Kit", origin: :generated, state: :auto_active)
      SitemapAutolinkEntry
        .create!(
          url: "https://example.com/shop/deluxe-widget-kit",
          title: "Deluxe Widget Kit",
          content_type: "product",
          source: "sitemap",
        )
        .terms
        .create!(phrase: "Deluxe Widget Kit", origin: :generated, state: :auto_active)
      SitemapAutolink::Catalog.bump_version!

      get "#{base}/overlaps"
      overlap = response.parsed_body["overlaps"].first
      expect(overlap["phrase"]).to eq("widget kit")
      expect(overlap["covered_by"].map { |c| c["phrase"] }).to eq(["deluxe widget kit"])
      expect(response.parsed_body["same_destination"]).to eq(0)
    end

    it "searches by either keyword" do
      get "#{base}/overlaps", params: { q: "nothing-like-this" }
      expect(response.parsed_body["total"]).to eq(0)

      get "#{base}/overlaps", params: { q: "Widget Frame" }
      expect(response.parsed_body["overlaps"].map { |o| o["phrase"] }).to eq(["frame kit"])
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

    # A headline figure that disagrees with the page it links to is
    # worse than no figure, so the two are asserted against each other
    # in a state where the count is not trivially zero.
    it "agrees with the overview's contested count" do
      get "#{base}/collisions"
      competing = response.parsed_body["competing"]
      expect(competing).to eq(1)

      get "#{base}/status"
      expect(response.parsed_body["stats"]["contested"]).to eq(competing)
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

    # A page that cannot link the phrase has already lost it — there is
    # nothing to decide, so it is not a conflict. Most of the report was
    # this once the catalog got big.
    it "leaves out a phrase only one page can link" do
      rival.update!(enabled: false)
      SitemapAutolink::Catalog.bump_version!

      get "#{base}/collisions"
      expect(response.parsed_body["collisions"]).to be_empty
      expect(response.parsed_body["competing"]).to eq(0)
      expect(response.parsed_body["settled"]).to eq(1)
    end

    # Scoping DETECTION to active entries made the report disagree with
    # the catalog on screen: pages visibly claiming the same phrase were
    # reported as no conflict at all. Detect broadly, then say which of
    # them is actually in the fight — and why the others are not.
    it "shows the settled ones on request, with the reason each is out" do
      rival.update!(enabled: false)
      SitemapAutolink::Catalog.bump_version!

      get "#{base}/collisions", params: { include_inactive: "true" }
      collision = response.parsed_body["collisions"].first
      expect(collision["phrase"]).to eq("widget frame kit")
      expect(collision["linking_candidates"]).to eq(1)
      expect(collision["candidates"].map { |c| [c["url"], c["linking"]] }).to contain_exactly(
        [entry.url, true],
        [rival.url, false],
      )
      expect(collision["candidates"].find { |c| c["url"] == rival.url }["page_state"]).to eq(
        "disabled",
      )
    end

    it "names a page gone from the sitemap as the reason it is out" do
      rival.update!(removed_from_source: true)
      SitemapAutolink::Catalog.bump_version!

      get "#{base}/collisions", params: { include_inactive: "true" }
      collision = response.parsed_body["collisions"].first
      expect(collision["candidates"].find { |c| c["url"] == rival.url }["page_state"]).to eq(
        "removed",
      )
    end

    it "reports a phrase whose claimants are all awaiting review" do
      SitemapAutolinkTerm.update_all(state: SitemapAutolinkTerm.states[:pending_review])
      SitemapAutolink::Catalog.bump_version!

      get "#{base}/collisions", params: { include_inactive: "true" }
      expect(response.parsed_body["collisions"].first["phrase"]).to eq("widget frame kit")
      expect(response.parsed_body["collisions"].first["linking_candidates"]).to eq(0)
    end

    # "Linking" is not one column. A page whose type the enabled-types
    # setting rules out never compiles into a rule, so it is not
    # competing for anything — and reporting it as a conflict sent the
    # admin looking for a decision that had already been made in site
    # settings.
    it "does not count a page whose type cannot link" do
      SiteSetting.sitemap_autolink_enabled_types = "product"
      SitemapAutolink::Catalog.bump_version!

      get "#{base}/collisions"
      expect(response.parsed_body["collisions"]).to be_empty
      expect(response.parsed_body["settled"]).to eq(1)

    end

    # The page is live and its keyword approved, so neither of those can
    # be named as the reason. Saying "keyword approved" there answered
    # nothing; the honest answer is that a setting rules it out.
    it "blames the settings when the page is live and the keyword approved" do
      SiteSetting.sitemap_autolink_enabled_types = "product"
      SitemapAutolink::Catalog.bump_version!

      get "#{base}/collisions", params: { include_inactive: "true" }
      candidate =
        response.parsed_body["collisions"].first["candidates"].find { |c| c["url"] == rival.url }
      expect(candidate["page_state"]).to eq("live")
      expect(candidate["state"]).to eq("approved")
      expect(candidate["reason"]).to eq("settings")
    end

    # A phrase the manual-mappings setting claims is not a contest
    # between pages — the setting beats both, and no edit made here
    # would change what a post links.
    it "does not call it a contest when a manual mapping owns the phrase" do
      # Generated keywords, because a manual ALIAS ranks as manual too —
      # level with a manual MAPPING — and a tie is broken by URL, which
      # would leave the setting winning or losing by accident rather
      # than by rank.
      #
      # The mapping's URL then deliberately sorts AFTER both pages'.
      # Collisions break on priority first and only then on URL, so a
      # mapping that would lose the alphabetical tie-break proves it won
      # on rank — the thing this behaviour actually depends on.
      SitemapAutolinkTerm.find_each { |t| t.update!(origin: :generated, state: :auto_active) }
      SiteSetting.sitemap_autolink_manual_mappings =
        "Widget Frame Kit,https://example.com/zz-promo/widget-frame-kit,manual"
      SitemapAutolink::Catalog.bump_version!

      get "#{base}/collisions"
      expect(response.parsed_body["collisions"]).to be_empty
      expect(response.parsed_body["settled"]).to eq(1)
      # And the overview's headline agrees, rather than highlighting a
      # contest the page it links to says does not exist.
      get "#{base}/status"
      expect(response.parsed_body["stats"]["contested"]).to eq(0)

      get "#{base}/collisions", params: { include_inactive: "true" }
      collision = response.parsed_body["collisions"].first
      expect(collision["linking_candidates"]).to eq(0)
      expect(collision["candidates"].map { |c| c["reason"] }).to eq(%w[override override])
    end

    # A hand-created entry is the one place an unsafe URL can enter the
    # catalog, and compilation drops it — so it is no one's rival.
    it "does not count a page whose URL could never compile into a link" do
      rival.update_columns(url: "javascript:alert(1)")
      SitemapAutolink::Catalog.bump_version!

      get "#{base}/collisions"
      expect(response.parsed_body["collisions"]).to be_empty
      expect(response.parsed_body["settled"]).to eq(1)

      # And it is blamed on the URL rather than on the exclusion lists,
      # which say nothing about this page.
      get "#{base}/collisions", params: { include_inactive: "true" }
      candidate =
        response.parsed_body["collisions"].first["candidates"].find { |c| c["url"] != entry.url }
      expect(candidate["reason"]).to eq("unlinkable_url")
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

  describe "#resolve_collision" do
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

    it "gives the phrase to one page by disabling it on the others" do
      before_version = SitemapAutolink::Catalog.version

      post "#{base}/collisions/resolve",
           params: {
             phrase: "Widget Frame Kit",
             entry_id: entry.id,
           }

      expect(response.status).to eq(200)
      expect(response.parsed_body["disabled"]).to eq(1)
      expect(entry.terms.first.reload.state).to eq("approved")
      expect(rival.terms.first.reload.state).to eq("disabled")
      expect(SitemapAutolink::Catalog.version).to be > before_version
    end

    # Only this phrase moves. Lowering the page's priority number would
    # have handed it every other keyword it shares as well.
    it "leaves the pages' other keywords alone" do
      rival.terms.create!(phrase: "Gasket Set", origin: :manual, state: :approved)

      post "#{base}/collisions/resolve",
           params: {
             phrase: "Widget Frame Kit",
             entry_id: entry.id,
           }

      expect(rival.terms.find_by(normalized_phrase: "gasket set").state).to eq("approved")
    end

    it "approves a winner that was awaiting review" do
      entry.terms.first.update!(state: :pending_review)
      SitemapAutolink::Catalog.bump_version!

      post "#{base}/collisions/resolve",
           params: {
             phrase: "Widget Frame Kit",
             entry_id: entry.id,
           }

      expect(entry.terms.first.reload.state).to eq("approved")
    end

    # The damage this refusal prevents: handing the phrase to a page that
    # cannot link it disabled the keyword on every page that could, so
    # the phrase linked NOWHERE — and the old code reported that after
    # the write had already landed.
    it "refuses to hand the phrase to a page that is gone from the sitemap" do
      entry.update!(removed_from_source: true)

      post "#{base}/collisions/resolve",
           params: {
             phrase: "Widget Frame Kit",
             entry_id: entry.id,
           }

      expect(response.status).to eq(422)
      expect(response.parsed_body["error"]).to include("gone from the sitemap")
      expect(rival.terms.first.reload.state).to eq("approved")
    end

    it "refuses to hand the phrase to a disabled page" do
      entry.update!(enabled: false)

      post "#{base}/collisions/resolve",
           params: {
             phrase: "Widget Frame Kit",
             entry_id: entry.id,
           }

      expect(response.status).to eq(422)
      expect(rival.terms.first.reload.state).to eq("approved")
    end

    # Nothing here outranks the setting, so the edit would disable a
    # working keyword and change no link at all.
    it "refuses when a manual mapping already owns the phrase" do
      # Generated keywords rank below a manual mapping; manual aliases
      # rank level with one and would be decided by the URL tie-break.
      SitemapAutolinkTerm.find_each { |t| t.update!(origin: :generated, state: :auto_active) }
      SiteSetting.sitemap_autolink_manual_mappings =
        "Widget Frame Kit,https://example.com/zz-promo/widget-frame-kit,manual"
      SitemapAutolink::Catalog.bump_version!

      post "#{base}/collisions/resolve",
           params: {
             phrase: "Widget Frame Kit",
             entry_id: entry.id,
           }

      expect(response.status).to eq(422)
      expect(response.parsed_body["error"]).to include("sitemap_autolink_manual_mappings")
      expect(rival.terms.first.reload.state).to eq("auto_active")
    end

    it "refuses a page that does not claim the phrase" do
      other =
        SitemapAutolinkEntry.create!(
          url: "https://example.com/shop/gasket-set",
          title: "Gasket Set",
          content_type: "product",
          source: "sitemap",
        )

      post "#{base}/collisions/resolve",
           params: {
             phrase: "Widget Frame Kit",
             entry_id: other.id,
           }

      expect(response.status).to eq(404)
      expect(rival.terms.first.reload.state).to eq("approved")
    end
  end

  describe "#sitemaps" do
    before { sign_in(admin) }

    fab!(:wiki_entry) do
      SitemapAutolinkEntry.create!(
        url: "https://example.com/wiki/gasket-lore",
        title: "Gasket Lore",
        content_type: "wiki",
        source: "sitemap",
        title_source: "page",
      )
    end

    # The admin PAGE also lives under .../sitemaps, and page routes are
    # registered first, so a JSON endpoint named plainly "sitemaps" is
    # answered with the admin SPA shell instead — silently, with a 200.
    it "answers with JSON, not the admin page shell" do
      get "#{base}/sitemaps/list"
      expect(response.status).to eq(200)
      expect(response.media_type).to eq("application/json")
    end

    it "lists each configured source with the children found inside it" do
      index = list_in(nil, "https://example.com/sitemap.xml", kind: "index", configured: true)
      child = list_in(entry, "https://example.com/sitemap-products.xml")
      child.update!(parent_url: index.url, url_count: 1_400)
      waiting = list_in(nil, "https://example.com/sitemap-tags.xml", status: "pending")
      waiting.update!(parent_url: index.url, url_count: 41_000, url_count_partial: true)

      get "#{base}/sitemaps/list"
      body = response.parsed_body
      expect(body["pending"]).to eq(1)
      # The index first, then its own children beneath it.
      expect(body["sitemaps"].map { |s| s["url"] }).to eq(
        [
          "https://example.com/sitemap.xml",
          "https://example.com/sitemap-products.xml",
          "https://example.com/sitemap-tags.xml",
        ],
      )
      products = body["sitemaps"].find { |s| s["url"].include?("products") }
      expect(products["entries"]).to eq(1)
      expect(products["live_entries"]).to eq(1)
      tags = body["sitemaps"].find { |s| s["url"].include?("tags") }
      # The size is the whole point of listing it before importing it.
      expect(tags["url_count"]).to eq(41_000)
      # An index imports nothing itself, so its row reports how the
      # decisions it created stand rather than leaving the admin to
      # count indented rows.
      parent = body["sitemaps"].first
      expect(parent).to include(
        "children" => 2,
        "children_imported" => 1,
        "children_pending" => 1,
        "children_ignored" => 0,
      )
      expect(tags["url_count_partial"]).to eq(true)
      expect(tags["status"]).to eq("pending")
    end

    it "approves a sitemap for import" do
      sitemap = list_in(nil, "https://example.com/sitemap-tags.xml", status: "pending")

      put "#{base}/sitemaps/#{sitemap.id}", params: { status: "enabled" }
      expect(response.status).to eq(200)
      expect(sitemap.reload.status).to eq("enabled")
    end

    it "rejects a status it does not recognise" do
      sitemap = list_in(nil, "https://example.com/sitemap-tags.xml", status: "pending")
      put "#{base}/sitemaps/#{sitemap.id}", params: { status: "maybe" }
      expect(response.status).to eq(400)
    end

    # Turning a sitemap off has to take effect now, not at the next sync
    # — otherwise its pages sit there looking imported and linking.
    it "marks pages gone when the only sitemap listing them stops importing" do
      sitemap = list_in(entry, "https://example.com/sitemap-products.xml")

      put "#{base}/sitemaps/#{sitemap.id}", params: { status: "ignored" }
      expect(response.parsed_body["orphaned"]).to eq(1)
      expect(entry.reload.removed_from_source).to eq(true)
      expect(SitemapAutolinkEntry.exists?(entry.id)).to eq(true)
    end

    # A page listed elsewhere too is NOT gone; it just lost one listing.
    it "leaves a page alone when another sitemap still lists it" do
      sitemap = list_in(entry, "https://example.com/sitemap-products.xml")
      list_in(entry, "https://example.com/sitemap-featured.xml")

      put "#{base}/sitemaps/#{sitemap.id}", params: { status: "ignored" }
      expect(response.parsed_body["orphaned"]).to eq(0)
      expect(entry.reload.removed_from_source).to eq(false)
    end

    it "deletes the pages a sitemap brought in when asked to purge" do
      sitemap = list_in(entry, "https://example.com/sitemap-products.xml")
      entry.terms.create!(phrase: "Widget Frame Kit", origin: :generated, state: :auto_active)
      list_in(wiki_entry, "https://example.com/sitemap-wiki.xml")

      put "#{base}/sitemaps/#{sitemap.id}", params: { status: "ignored", purge: "true" }
      expect(response.parsed_body["purged"]).to eq(1)
      expect(SitemapAutolinkEntry.exists?(entry.id)).to eq(false)
      expect(SitemapAutolinkTerm.where(entry_id: entry.id)).to be_empty
      # Only the pages that sitemap brought in.
      expect(SitemapAutolinkEntry.exists?(wiki_entry.id)).to eq(true)
    end
  end

  describe "#purge_entries" do
    before { sign_in(admin) }

    fab!(:gone_entry) do
      SitemapAutolinkEntry.create!(
        url: "https://example.com/shop/discontinued",
        title: "Discontinued Widget",
        content_type: "product",
        source: "sitemap",
        title_source: "page",
        removed_from_source: true,
      )
    end

    it "deletes only the pages that are gone from the sitemap" do
      gone_entry.terms.create!(phrase: "Discontinued Widget", origin: :generated, state: :auto_active)

      get "#{base}/entries"
      expect(response.parsed_body["gone_pages"]).to eq(1)

      delete "#{base}/entries/purge"
      expect(response.parsed_body["purged"]).to eq(1)
      expect(SitemapAutolinkEntry.exists?(gone_entry.id)).to eq(false)
      expect(SitemapAutolinkTerm.where(entry_id: gone_entry.id)).to be_empty
      # A live page is never touched by a purge.
      expect(SitemapAutolinkEntry.exists?(entry.id)).to eq(true)
    end

    it "purges within the current filter only" do
      other =
        SitemapAutolinkEntry.create!(
          url: "https://example.com/wiki/retired-lore",
          title: "Retired Lore",
          content_type: "wiki",
          source: "sitemap",
          title_source: "page",
          removed_from_source: true,
        )

      delete "#{base}/entries/purge", params: { filter: { type: "wiki" } }
      expect(response.parsed_body["purged"]).to eq(1)
      expect(SitemapAutolinkEntry.exists?(other.id)).to eq(false)
      expect(SitemapAutolinkEntry.exists?(gone_entry.id)).to eq(true)
    end

    it "purges within the sitemap filter only" do
      list_in(gone_entry, "https://example.com/sitemap-products.xml")
      other =
        SitemapAutolinkEntry.create!(
          url: "https://example.com/wiki/retired-lore",
          title: "Retired Lore",
          content_type: "wiki",
          source: "sitemap",
          title_source: "page",
          removed_from_source: true,
        )
      list_in(other, "https://example.com/sitemap-wiki.xml")

      delete "#{base}/entries/purge",
             params: {
               filter: {
                 sitemap: "https://example.com/sitemap-wiki.xml",
               },
             }
      expect(response.parsed_body["purged"]).to eq(1)
      expect(SitemapAutolinkEntry.exists?(other.id)).to eq(false)
      expect(SitemapAutolinkEntry.exists?(gone_entry.id)).to eq(true)
    end

    # Purged means forgotten: nothing remembers the URL, so a sync that
    # meets it again ingests it as a page it has never seen.
    it "forgets a purged URL completely, so it comes back as new" do
      list_in(gone_entry, "https://example.com/sitemap-products.xml")
      delete "#{base}/entries/purge"

      expect(SitemapAutolinkEntry.find_by(url: gone_entry.url)).to be_nil
      expect(SitemapAutolinkEntrySitemap.where(entry_id: gone_entry.id)).to be_empty
    end

    it "purges a single page from its card" do
      delete "#{base}/entries/#{gone_entry.id}"
      expect(response.status).to eq(200)
      expect(SitemapAutolinkEntry.exists?(gone_entry.id)).to eq(false)
    end

    # Deleting a page that is still listed in a sitemap cannot succeed:
    # the next sync ingests it straight back. Disabling is the control
    # that actually holds, so the API refuses rather than performing a
    # deletion that quietly undoes itself.
    it "refuses to delete a page that is still in a sitemap" do
      delete "#{base}/entries/#{entry.id}"
      expect(response.status).to eq(422)
      expect(response.parsed_body["error"]).to include("disable it instead")
      expect(SitemapAutolinkEntry.exists?(entry.id)).to eq(true)
    end

    it "refuses even when the page is merely disabled" do
      entry.update!(enabled: false)
      delete "#{base}/entries/#{entry.id}"
      expect(response.status).to eq(422)
      expect(SitemapAutolinkEntry.exists?(entry.id)).to eq(true)
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
