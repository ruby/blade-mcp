# frozen_string_literal: true

module BladeMcp
  module Text
    QUOTE = /\A[ \t]*[>＞]/

    module_function

    def without_quotes(text)
      text.to_s.each_line.grep_v(QUOTE).join.gsub(/\n{3,}/, "\n\n")
    end

    def passage(subject, body)
      "#{subject}\n\n#{without_quotes(body)}".gsub(/[ \t]+/, ' ').strip
    end

    def snippet(body, terms = [], size = 240)
      flat = without_quotes(body).gsub(/\s+/, ' ').strip
      down = flat.downcase
      hit = terms.filter_map { |term| down.index(term.downcase) }.min || 0
      start = [hit - size / 4, 0].max
      "#{'...' if start > 0}#{flat[start, size]}#{'...' if start + size < flat.size}"
    end
  end
end
