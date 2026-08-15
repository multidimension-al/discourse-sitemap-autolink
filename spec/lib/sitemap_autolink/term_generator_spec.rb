# frozen_string_literal: true

RSpec.describe SitemapAutolink::TermGenerator do
  let(:settings) do
    {
      min_phrase_length: 5,
      min_phrase_words: 2,
      generate_plurals: true,
      excluded_terms: Set.new,
    }
  end

  def phrases(result)
    result.map { |c| SitemapAutolink::Matcher.normalize(c[:phrase]) }
  end

  def active(result)
    result.select { |c| c[:state] == :auto_active }
  end

  it "generates the canonical title and prefix-stripped variants" do
    result = described_class.generate("Accessories: Widget Frame Kit", "product", settings)
    expect(phrases(result)).to include("accessories: widget frame kit", "widget frame kit")
    expect(active(result).map { |c| c[:phrase] }).to include("Widget Frame Kit")
  end

  it "strips trailing parentheticals" do
    result = described_class.generate("Widget Frame Kit (Mark II)", "product", settings)
    expect(phrases(result)).to include("widget frame kit")
  end

  it "adds plural variants when enabled and skips them when disabled" do
    on = described_class.generate("Widget Frame Kit", "product", settings)
    expect(phrases(on)).to include("widget frame kits")
    off = described_class.generate("Widget Frame Kit", "product", settings.merge(generate_plurals: false))
    expect(phrases(off)).not_to include("widget frame kits")
  end

  it "does not invent semantic aliases" do
    result = described_class.generate("Grey Elbow Pads", "product", settings)
    expect(phrases(result)).not_to include("elbow pads")
  end

  it "sends short phrases to review instead of activating them" do
    result = described_class.generate("Caps", "category", settings)
    expect(active(result)).to be_empty
    expect(result.map { |c| c[:reason] }).to include("too_short")
  end

  it "sends single-word phrases to review, except letter+digit tokens" do
    single = described_class.generate("Gizmotron", "wiki", settings)
    expect(active(single)).to be_empty
    expect(single.map { |c| c[:reason] }).to include("below_min_words")

    model = described_class.generate("Mark-2", "wiki", settings)
    expect(active(model).map { |c| c[:phrase] }).to include("Mark-2")
  end

  it "sends generic single words to review" do
    result = described_class.generate("Banks", "category", settings.merge(min_phrase_length: 4))
    expect(active(result)).to be_empty
    expect(result.map { |c| c[:reason] }).to include("generic_word")
  end

  it "drops globally excluded terms entirely" do
    excluded = settings.merge(excluded_terms: Set.new(["widget kit"]))
    result = described_class.generate("Widget Kit", "wiki", excluded)
    expect(phrases(result)).not_to include("widget kit")
  end

  it "handles & and 'and' variants" do
    result = described_class.generate("Bumper & Siren Kit", "product", settings)
    expect(phrases(result)).to include("bumper and siren kit")
  end
end
