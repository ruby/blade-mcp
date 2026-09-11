# frozen_string_literal: true

require_relative 'db'
require_relative 'inference'
require_relative 'text'

module BladeMcp
  # Fills in embeddings for messages that have none yet. Redmine
  # notifications are never embedded, and ruby-talk stays out of the default
  # lists until it is decided to add it with --lists.
  class Embedder
    LISTS = %w[ruby-core ruby-dev ruby-list ruby-ext ruby-math].freeze

    def initialize(conn, client, log: $stdout)
      @conn = conn
      @client = client
      @log = log
    end

    def run(lists: LISTS, limit: nil)
      done = 0
      loop do
        size = [Inference::Embedding::MAX_INPUTS, limit && limit - done].compact.min
        break unless size.positive?
        rows = @conn.exec_params(<<~SQL, [lists, size]).to_a
          SELECT id, subject, body FROM messages
          WHERE embedding IS NULL AND NOT notification AND list = ANY($1::text[])
          ORDER BY id
          LIMIT $2
        SQL
        break if rows.empty?
        texts = rows.map do |row|
          text = Text.passage(row['subject'], row['body'], Inference::Embedding::MAX_CHARS)
          text.empty? ? '(empty)' : text
        end
        vectors = @client.embed(texts, input_type: 'search_document')
        @conn.transaction do
          rows.zip(vectors) do |row, vector|
            @conn.exec_params('UPDATE messages SET embedding = $2::vector WHERE id = $1', [row['id'], DB.vector(vector)])
          end
        end
        done += rows.size
        @log.puts "embedded #{done} messages"
      end
      done
    end
  end
end
