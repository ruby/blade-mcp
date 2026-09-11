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
    RATE_LIMIT_WAIT = 60
    RATE_LIMIT_RETRIES = 10

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
        vectors = embed(texts)
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

    private

    # A backfill easily spends the 800k tokens per minute of cohere-embed-v4,
    # so it waits for the window to pass instead of giving up.
    def embed(texts)
      waits = 0
      begin
        @client.embed(texts, input_type: 'search_document')
      rescue Inference::RateLimited => e
        raise if (waits += 1) > RATE_LIMIT_RETRIES
        seconds = e.retry_after || RATE_LIMIT_WAIT
        @log.puts "rate limited, retrying in #{seconds}s"
        sleep seconds
        retry
      end
    end
  end
end
