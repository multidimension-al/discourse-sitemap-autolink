# frozen_string_literal: true

RSpec.describe GbfansAutolink::Matcher do
  def rule(phrase, url, priority: 1, type: "product")
    { phrase: phrase, url: url, type: type, priority: priority }
  end

  def scan(rules, text)
    described_class.new(rules).scan(described_class.normalize(text))
  end

  describe ".normalize" do
    it "downcases and folds typographic apostrophes, preserving length" do
      expect(described_class.normalize("Tobin’s Spirit Guide")).to eq("tobin's spirit guide")
      expect(described_class.normalize("Tobin’s").length).to eq("Tobin’s".length)
    end
  end

  describe "#scan" do
    it "finds all occurrences of all phrases in one pass" do
      rules = [rule("elbow pads", "/a"), rule("proton pack", "/b")]
      found = scan(rules, "New elbow pads for my proton pack. Old elbow pads.")
      expect(found.map { |c| c[:rule][:url] }).to contain_exactly("/a", "/b", "/a")
    end

    it "respects word boundaries" do
      expect(scan([rule("pack", "/a")], "Repacking backpacks")).to be_empty
      expect(scan([rule("pack", "/a")], "My pack, ready.")).to have_attributes(size: 1)
    end

    it "matches at string start and end" do
      found = scan([rule("elbow pads", "/a")], "elbow pads")
      expect(found.size).to eq(1)
      expect(found.first[:start]).to eq(0)
    end

    it "finds nested and overlapping phrase candidates" do
      rules = [rule("proton pack", "/a"), rule("hasbro proton pack", "/b")]
      found = scan(rules, "A hasbro proton pack here.")
      expect(found.map { |c| c[:rule][:url] }).to contain_exactly("/a", "/b")
    end
  end

  describe ".resolve" do
    let(:counter) { GbfansAutolink::LinkCounter.new(max_per_destination: 1, max_total: 0) }

    it "prefers leftmost, then longest, then priority" do
      short = rule("proton pack", "/wiki", priority: 3)
      long = rule("hasbro proton pack", "/shop", priority: 2)
      candidates = [
        { start: 7, length: 11, rule: short },
        { start: 0, length: 18, rule: long },
      ]
      accepted = described_class.resolve(candidates, counter)
      expect(accepted.map { |c| c[:rule][:url] }).to eq(["/shop"])
    end

    it "lower priority number wins exact ties" do
      a = rule("proton pack", "/manual", priority: 0)
      b = rule("proton pack", "/wiki", priority: 3)
      candidates = [
        { start: 0, length: 11, rule: b },
        { start: 0, length: 11, rule: a },
      ]
      accepted = described_class.resolve(candidates, counter)
      expect(accepted.map { |c| c[:rule][:url] }).to eq(["/manual"])
    end

    it "caps per destination across nodes and keeps first occurrence" do
      r = rule("elbow pads", "/a")
      candidates = [
        { start: 0, length: 10, rule: r, node_index: 1 },
        { start: 0, length: 10, rule: r, node_index: 0 },
      ]
      accepted = described_class.resolve(candidates, counter)
      expect(accepted.size).to eq(1)
      expect(accepted.first[:node_index]).to eq(0)
    end

    it "does not re-award a span claimed by a capped winner" do
      capped = rule("hasbro proton pack", "/shop", priority: 1)
      other = rule("proton pack", "/wiki", priority: 3)
      counter.record("/shop") # simulate allowance already used
      candidates = [
        { start: 0, length: 18, rule: capped },
        { start: 7, length: 11, rule: other },
      ]
      accepted = described_class.resolve(candidates, counter)
      expect(accepted).to be_empty
    end

    it "applies the total cap in document order" do
      candidates = [
        { start: 0, length: 5, rule: rule("alpha", "/1") },
        { start: 10, length: 4, rule: rule("beta", "/2") },
        { start: 20, length: 5, rule: rule("gamma", "/3") },
      ]
      limited = GbfansAutolink::LinkCounter.new(max_per_destination: 1, max_total: 2)
      accepted = described_class.resolve(candidates, limited)
      expect(accepted.map { |c| c[:rule][:url] }).to eq(%w[/1 /2])
    end
  end
end
