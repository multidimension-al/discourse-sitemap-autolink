# frozen_string_literal: true

module GbfansAutolink
  # Applies a compiled ruleset to a cooked-post document (the Loofah/
  # Nokogiri fragment CookedPostProcessor hands to :post_process_cooked).
  #
  # Only text nodes outside excluded subtrees are considered; existing
  # links, code, preformatted blocks, oneboxes and (configurably) quotes
  # are never modified. Attribute values and URLs can never match because
  # they are not text nodes, and bare URLs/emails were already turned
  # into <a> elements by markdown-it before this runs.
  class LinkApplier
    SKIP_TAGS = %w[a code pre iframe script style svg math kbd samp var textarea].freeze
    SKIP_CLASSES = %w[onebox lightbox-wrapper meta].freeze
    QUOTE_TAGS = %w[blockquote].freeze

    # doc: Nokogiri node (fragment or element)
    # ruleset: GbfansAutolink::Ruleset
    # options: max_per_destination:, max_total:, skip_quotes:, base_url:
    # Returns the number of links inserted.
    def self.apply!(doc, ruleset, options)
      return 0 if ruleset.nil? || ruleset.empty?

      text_nodes = collect_text_nodes(doc, skip_quotes: options[:skip_quotes])
      return 0 if text_nodes.empty?

      matcher = ruleset.matcher
      candidates = []
      text_nodes.each_with_index do |node, node_index|
        content = node.content
        next if content.length < 2
        matcher
          .scan(Matcher.normalize(content))
          .each do |candidate|
            candidate[:node_index] = node_index
            candidate[:node] = node
            candidates << candidate
          end
      end
      return 0 if candidates.empty?

      counter =
        LinkCounter.new(
          max_per_destination: options[:max_per_destination].to_i,
          max_total: options[:max_total].to_i,
        )
      accepted = Matcher.resolve(candidates, counter)
      accepted
        .group_by { |candidate| candidate[:node] }
        .each { |node, matches| apply_to_node(node, matches, options[:base_url].to_s) }
      accepted.size
    end

    def self.collect_text_nodes(root, skip_quotes:, out: [])
      root.children.each do |child|
        if child.text?
          out << child
        elsif child.element?
          next if skip_element?(child, skip_quotes: skip_quotes)
          collect_text_nodes(child, skip_quotes: skip_quotes, out: out)
        end
      end
      out
    end

    def self.skip_element?(element, skip_quotes:)
      name = element.name.downcase
      return true if SKIP_TAGS.include?(name)
      classes = (element["class"] || "").split
      return true if classes.any? { |cls| SKIP_CLASSES.include?(cls) }
      if skip_quotes
        return true if QUOTE_TAGS.include?(name)
        return true if name == "aside" && classes.include?("quote")
      end
      false
    end

    # Matches are non-overlapping within the node. Rebuild the node as
    # text + <a> + text … preserving the original casing and characters.
    def self.apply_to_node(node, matches, base_url)
      doc = node.document
      content = node.content
      replacement = []
      cursor = 0
      matches
        .sort_by { |m| m[:start] }
        .each do |match|
          rule = match[:rule]
          if match[:start] > cursor
            replacement << Nokogiri::XML::Text.new(content[cursor...match[:start]], doc)
          end
          link = Nokogiri::XML::Node.new("a", doc)
          link["href"] = absolute_url(rule[:url], base_url)
          link["class"] = "gbfans-autolink gbfans-autolink-#{rule[:type]}"
          link["data-gbfans-autolink"] = "true"
          link["data-gbfans-link-type"] = rule[:type].to_s
          link["data-gbfans-term"] = rule[:phrase]
          link["data-gbfans-link-id"] = rule[:entry_id].to_s if rule[:entry_id]
          link.content = content[match[:start], match[:length]]
          replacement << link
          cursor = match[:start] + match[:length]
        end
      replacement << Nokogiri::XML::Text.new(content[cursor..], doc) if cursor < content.length

      replacement.each { |new_node| node.add_previous_sibling(new_node) }
      node.remove
    end

    def self.absolute_url(url, base_url)
      return url if url.start_with?("http://", "https://", "//")
      base_url.chomp("/") + url
    end
  end
end
