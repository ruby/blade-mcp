# frozen_string_literal: true

require_relative 'bigram'
require_relative 'db'
require_relative 'inference'
require_relative 'text'

module BladeMcp
  # Full-text and vector candidates are merged with reciprocal rank fusion,
  # and the head of the merged list is reordered by the rerank model. Either
  # client may be absent, which leaves the full-text ranking in charge.
  class Search
    CANDIDATES = 40
    RERANK = 30
    RERANK_CHARS = 4000
    RRF_K = 60

    def initialize(store, embedder: nil, reranker: nil, log: $stderr)
      @store = store
      @embedder = embedder
      @reranker = reranker
      @log = log
    end

    def call(query, limit: 10, **filters)
      depth = [CANDIDATES, limit].max
      rankings = [lexical(query, depth, filters)]
      rankings << semantic(query, depth, filters) if @embedder
      rows = @store.rows(fuse(rankings).first([RERANK, limit].max))
      rows = rerank(query, rows) if @reranker && rows.size > 1
      rows.first(limit)
    end

    private

    def lexical(query, depth, filters)
      phrases = Bigram.phrases(query)
      return [] if phrases.empty?
      params = phrases.dup
      tsquery = phrases.each_index.map { |i| "phraseto_tsquery('simple', $#{i + 1})" }.join(' && ')
      where = ['tsv @@ q', *conditions(params, **filters)]
      @store.conn.exec_params(<<~SQL, params).column_values(0)
        SELECT id FROM messages, (SELECT #{tsquery}) AS query (q)
        WHERE #{where.join(' AND ')}
        ORDER BY ts_rank_cd(tsv, q) DESC, id
        LIMIT #{depth}
      SQL
    end

    # Without iterative scans, the index stops after hnsw.ef_search (40)
    # rows, before the list and date filters are applied.
    def semantic(query, depth, filters)
      params = [DB.vector(@embedder.embed([query], input_type: 'search_query').first)]
      where = ['embedding IS NOT NULL', *conditions(params, **filters)]
      @store.conn.transaction do |conn|
        conn.exec('SET LOCAL hnsw.iterative_scan = strict_order')
        conn.exec_params(<<~SQL, params).column_values(0)
          SELECT id FROM messages WHERE #{where.join(' AND ')} ORDER BY embedding <=> $1::vector LIMIT #{depth}
        SQL
      end
    rescue Inference::Error => e
      @log.puts "semantic search skipped: #{e.message}"
      []
    end

    def conditions(params, lists: nil, since: nil, before: nil, include_notifications: false)
      sql = []
      sql << "list = ANY($#{params.push(lists).size}::text[])" if lists
      sql << "date >= $#{params.push(since).size}" if since
      sql << "date < $#{params.push(before).size}" if before
      sql << 'NOT notification' unless include_notifications
      sql
    end

    def fuse(rankings)
      scores = Hash.new(0.0)
      rankings.each do |ids|
        ids.each.with_index(1) { |id, rank| scores[id] += 1.0 / (RRF_K + rank) }
      end
      scores.sort_by { |id, score| [-score, id] }.map(&:first)
    end

    def rerank(query, rows)
      documents = rows.map { |row| Text.passage(row['subject'], row['body'], RERANK_CHARS) }
      @reranker.rerank(query, documents).map { |index, _score| rows[index] }
    rescue Inference::Error => e
      @log.puts "rerank skipped: #{e.message}"
      rows
    end
  end
end
