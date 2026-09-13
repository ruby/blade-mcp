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
      embedded = 0
      loop do
        size = [Inference::Embedding::MAX_INPUTS, limit && limit - done].compact.min
        break unless size.positive?
        rows = @conn.exec_params(<<~SQL, [lists, size]).to_a
          SELECT id, list, seq, subject, body FROM messages
          WHERE embedding IS NULL AND NOT embedding_skipped AND NOT notification AND list = ANY($1::text[])
          ORDER BY id
          LIMIT $2
        SQL
        break if rows.empty?
        skipped = []
        saved = store(rows, skipped)
        # A whole batch turned away says more about the client than about the
        # messages, so none of them is marked.
        raise Inference::Blocked, 'every message in a batch was blocked' if saved.zero? && rows.size > 1
        skipped.each do |row|
          @conn.exec_params('UPDATE messages SET embedding_skipped = true WHERE id = $1', [row['id']])
          @log.puts "#{row['list']}:#{row['seq']} was blocked, left without an embedding"
        end
        done += rows.size
        embedded += saved
        @log.puts "embedded #{embedded} messages"
      end
      embedded
    end

    private

    # Only the offending message is blocked, so a blocked batch is halved
    # until it stands alone.
    def store(rows, skipped)
      texts = rows.map do |row|
        text = Text.passage(row['subject'], row['body'])
        text.empty? ? '(empty)' : text
      end
      vectors = embed(texts)
      @conn.transaction do
        rows.zip(vectors) do |row, vector|
          @conn.exec_params('UPDATE messages SET embedding = $2::vector WHERE id = $1', [row['id'], DB.vector(vector)])
        end
      end
      rows.size
    rescue Inference::Blocked
      if rows.size == 1
        skipped.concat(rows)
        0
      else
        rows.each_slice(rows.size.ceildiv(2)).sum { |half| store(half, skipped) }
      end
    end

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
