# frozen_string_literal: true

RSpec.describe SitemapAutolink::Matcher do
  def rule(phrase, url, priority: 1, type: "product")
    { phrase: phrase, url: url, type: type, priority: priority }
  end

  def scan(rules, text)
    described_class.new(rules).scan(described_class.normalize(text))
  end

  describe ".normalize" do
    it "downcases and folds typographic apostrophes, preserving length" do
      expect(described_class.normalize("Foreman’s Field Guide")).to eq("foreman's field guide")
      expect(described_class.normalize("Foreman’s").length).to eq("Foreman’s".length)
    end

    it "folds non-breaking spaces to plain spaces, preserving length" do
      expect(described_class.normalize("Widget\u00A0Kit")).to eq("widget kit")
      expect(described_class.normalize("a\u00A0b").length).to eq(3)
    end
  end

  describe "#scan" do
    it "finds all occurrences of all phrases in one pass" do
      rules = [rule("widget kit", "/a"), rule("gasket set", "/b")]
      found = scan(rules, "New widget kit with a gasket set. Old widget kit.")
      expect(found.map { |c| c[:rule][:url] }).to contain_exactly("/a", "/b", "/a")
    end

    it "respects word boundaries" do
      expect(scan([rule("kit", "/a")], "Kitbashing toolkits")).to be_empty
      expect(scan([rule("kit", "/a")], "My kit, ready.")).to have_attributes(size: 1)
    end

    it "matches at string start and end" do
      found = scan([rule("widget kit", "/a")], "widget kit")
      expect(found.size).to eq(1)
      expect(found.first[:start]).to eq(0)
    end

    it "finds nested and overlapping phrase candidates" do
      rules = [rule("widget kit", "/a"), rule("deluxe widget kit", "/b")]
      found = scan(rules, "A deluxe widget kit here.")
      expect(found.map { |c| c[:rule][:url] }).to contain_exactly("/a", "/b")
    end

    it "matches phrases whose words are separated by non-breaking spaces" do
      found = scan([rule("widget kit", "/a")], "my widget\u00A0kit here")
      expect(found.size).to eq(1)
    end
  end

  describe ".resolve" do
    let(:counter) { SitemapAutolink::LinkCounter.new(max_per_destination: 1, max_total: 0) }

    it "prefers the longest phrase, then priority" do
      short = rule("widget kit", "/wiki", priority: 3)
      long = rule("deluxe widget kit", "/shop", priority: 2)
      candidates = [
        { start: 7, length: 10, rule: short },
        { start: 0, length: 17, rule: long },
      ]
      accepted = described_class.resolve(candidates, counter)
      expect(accepted.map { |c| c[:rule][:url] }).to eq(["/shop"])
    end

    # Ranking by position would hand this to "widget kit" purely because
    # it starts two characters earlier, burying the more specific phrase.
    it "prefers a longer phrase that starts LATER than a shorter one" do
      short = rule("widget kit", "/wiki")
      long = rule("kit deluxe frame", "/shop")
      candidates = [
        { start: 0, length: 10, rule: short },
        { start: 7, length: 16, rule: long },
      ]
      accepted = described_class.resolve(candidates, counter)
      expect(accepted.map { |c| c[:rule][:url] }).to eq(["/shop"])
    end

    # The per-destination budget must buy the fullest mention of a page,
    # not whichever stray word for it appeared first.
    it "spends a destination's budget on its most specific mention" do
      r = rule("widget kit", "/shop")
      full = rule("deluxe widget kit", "/shop")
      candidates = [
        { start: 0, length: 10, rule: r },
        { start: 40, length: 17, rule: full },
      ]
      accepted = described_class.resolve(candidates, counter)
      expect(accepted.map { |c| c[:start] }).to eq([40])
    end

    it "lower priority number wins exact ties" do
      a = rule("widget kit", "/manual", priority: 0)
      b = rule("widget kit", "/wiki", priority: 3)
      candidates = [
        { start: 0, length: 10, rule: b },
        { start: 0, length: 10, rule: a },
      ]
      accepted = described_class.resolve(candidates, counter)
      expect(accepted.map { |c| c[:rule][:url] }).to eq(["/manual"])
    end

    it "caps per destination across nodes and keeps first occurrence" do
      r = rule("widget kit", "/a")
      candidates = [
        { start: 0, length: 10, rule: r, node_index: 1 },
        { start: 0, length: 10, rule: r, node_index: 0 },
      ]
      accepted = described_class.resolve(candidates, counter)
      expect(accepted.size).to eq(1)
      expect(accepted.first[:node_index]).to eq(0)
    end

    it "does not re-award a span claimed by a capped winner" do
      capped = rule("deluxe widget kit", "/shop", priority: 1)
      other = rule("widget kit", "/wiki", priority: 3)
      counter.record("/shop") # simulate allowance already used
      candidates = [
        { start: 0, length: 17, rule: capped },
        { start: 7, length: 10, rule: other },
      ]
      accepted = described_class.resolve(candidates, counter)
      expect(accepted).to be_empty
    end

    it "spends the total cap on the most specific matches" do
      candidates = [
        { start: 0, length: 5, rule: rule("alpha", "/1") },
        { start: 10, length: 4, rule: rule("beta", "/2") },
        { start: 20, length: 5, rule: rule("gamma", "/3") },
      ]
      limited = SitemapAutolink::LinkCounter.new(max_per_destination: 1, max_total: 2)
      accepted = described_class.resolve(candidates, limited)
      expect(accepted.map { |c| c[:rule][:url] }).to eq(%w[/1 /3])
    end

    it "returns accepted matches in document order" do
      candidates = [
        { start: 20, length: 5, rule: rule("gamma", "/3"), node_index: 1 },
        { start: 0, length: 9, rule: rule("alphabeta", "/1"), node_index: 1 },
        { start: 4, length: 4, rule: rule("beta", "/2"), node_index: 0 },
      ]
      unlimited = SitemapAutolink::LinkCounter.new(max_per_destination: 0, max_total: 0)
      accepted = described_class.resolve(candidates, unlimited)
      expect(accepted.map { |c| c[:rule][:url] }).to eq(%w[/2 /1 /3])
    end
  end
end
