# frozen_string_literal: true

require_relative 'db'
require_relative 'inference'
require_relative 'patience'
require_relative 'statements'
require_relative 'text'

module BladeMcp
  # Fills in embeddings for messages and statements that have none yet.
  # Redmine notifications are never embedded, and ruby-talk stays out of the
  # default lists until it is decided to add it with --lists.
  class Embedder
    include Patience

    LISTS = %w[ruby-core ruby-dev ruby-list ruby-ext ruby-math].freeze

    def initialize(conn, client, log: $stdout)
      @conn = conn
      @client = client
      @log = log
    end

    def run(lists: LISTS, limit: nil)
      backfill('messages', limit) do |size|
        rows = @conn.exec_params(<<~SQL, [lists, size])
          SELECT id, list, seq, subject, body FROM messages
          WHERE embedding IS NULL AND NOT embedding_skipped AND NOT notification AND list = ANY($1::text[])
          ORDER BY id
          LIMIT $2
        SQL
        rows.map { |row| row.merge('label' => "#{row['list']}:#{row['seq']}", 'text' => Text.passage(row['subject'], row['body'])) }
      end
    end

    def run_statements(limit: nil)
      backfill('statements', limit) do |size|
        rows = @conn.exec_params(<<~SQL, [size])
          SELECT id, topic, summary, rationale, quote FROM statements
          WHERE embedding IS NULL AND NOT embedding_skipped
          ORDER BY id
          LIMIT $1
        SQL
        rows.map { |row| row.merge('label' => "statement #{row['id']}", 'text' => Statements.document(row)) }
      end
    end

    private

    def backfill(table, limit)
      done = 0
      embedded = 0
      loop do
        size = [Inference::Embedding::MAX_INPUTS, limit && limit - done].compact.min
        break unless size.positive?
        rows = yield(size)
        break if rows.empty?
        skipped = []
        saved = store(table, rows, skipped)
        # A whole batch turned away says more about the client than about the
        # rows, so none of them is marked.
        raise Inference::Blocked, "every row in a batch of #{table} was blocked" if saved.zero? && rows.size > 1
        skipped.each do |row|
          @conn.exec_params("UPDATE #{table} SET embedding_skipped = true WHERE id = $1", [row['id']])
          @log.puts "#{row['label']} was blocked, left without an embedding"
        end
        done += rows.size
        embedded += saved
        @log.puts "embedded #{embedded} #{table}"
      end
      embedded
    end

    # Only the offending row is blocked, so a blocked batch is halved until it
    # stands alone.
    def store(table, rows, skipped)
      vectors = embed(rows.map { |row| row['text'].empty? ? '(empty)' : row['text'] })
      @conn.transaction do
        rows.zip(vectors) do |row, vector|
          @conn.exec_params("UPDATE #{table} SET embedding = $2::vector WHERE id = $1", [row['id'], DB.vector(vector)])
        end
      end
      rows.size
    rescue Inference::Blocked
      if rows.size == 1
        skipped.concat(rows)
        0
      else
        rows.each_slice(rows.size.ceildiv(2)).sum { |half| store(table, half, skipped) }
      end
    end

    def embed(texts)
      patiently { @client.embed(texts, input_type: 'search_document') }
    end
  end
end
