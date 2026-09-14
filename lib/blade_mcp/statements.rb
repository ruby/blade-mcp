# frozen_string_literal: true

module BladeMcp
  # The statements extracted from what matz wrote or was reported to have
  # said.
  class Statements
    KINDS = %w[accepted rejected design naming policy opinion undecided condition principle].freeze

    def self.document(row)
      row.values_at('topic', 'summary', 'rationale', 'quote').compact.join("\n\n")
    end
  end
end
