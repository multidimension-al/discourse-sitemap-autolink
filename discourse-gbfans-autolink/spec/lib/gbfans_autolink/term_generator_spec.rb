# frozen_string_literal: true

RSpec.describe GbfansAutolink::TermGenerator do
  let(:settings) { { min_phrase_length: 5, min_wiki_words: 2, excluded_terms: Set.new } }

  def phrases(result)
    result.map { |c| GbfansAutolink::Matcher.normalize(c[:phrase]) }
  end

  def active(result)
    result.select { |c| c[:state] == :auto_active }
  end

  it "generates the canonical title and safe variants for products" do
    result = described_class.generate("Pack: ALICE Frame Padding", "product", settings)
    expect(phrases(result)).to include("pack: alice frame padding", "alice frame padding")
    expect(active(result).map { |c| c[:phrase] }).to include("ALICE Frame Padding")
  end

  it "strips trailing parentheticals" do
    result = described_class.generate("Clippard Brass Elbow (GB1 Ion Arm)", "product", settings)
    expect(phrases(result)).to include("clippard brass elbow")
  end

  it "adds plural variants for products but not wiki titles" do
    product = described_class.generate("Grey Elbow Pad", "product", settings)
    expect(phrases(product)).to include("grey elbow pads")
    wiki = described_class.generate("Vigo the Carpathian", "wiki", settings)
    expect(phrases(wiki)).not_to include("vigo the carpathians")
    expect(phrases(wiki)).to include("vigo the carpathian")
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

  it "sends single-word wiki titles to review, except letter+digit names" do
    gozer = described_class.generate("Gozer", "wiki", settings)
    expect(active(gozer)).to be_empty
    expect(gozer.map { |c| c[:reason] }).to include("single_word_wiki")

    ecto = described_class.generate("Ecto-1", "wiki", settings)
    expect(active(ecto).map { |c| c[:phrase] }).to include("Ecto-1")
  end

  it "sends generic single words to review" do
    result = described_class.generate("Banks", "category", settings.merge(min_phrase_length: 4))
    expect(active(result)).to be_empty
    expect(result.map { |c| c[:reason] }).to include("generic_word")
  end

  it "drops globally excluded terms entirely" do
    excluded = settings.merge(excluded_terms: Set.new(["proton pack"]))
    result = described_class.generate("Proton Pack", "wiki", excluded)
    expect(phrases(result)).not_to include("proton pack")
  end

  it "handles & and 'and' variants" do
    result = described_class.generate("Bumper & Siren Kit", "product", settings)
    expect(phrases(result)).to include("bumper and siren kit")
  end
end
