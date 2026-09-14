# frozen_string_literal: true

require_relative 'bigram'
require_relative 'db'
require_relative 'inference'

module BladeMcp
  # Full-text and vector candidates are merged with reciprocal rank fusion,
  # and the head of the merged list is reordered by the rerank model. Either
  # client may be absent, which leaves the full-text ranking in charge. The
  # corpus gives the dataset narrowed by the filters and the rows to return.
  class Search
    CANDIDATES = 40
    RERANK = 30
    RERANK_CHARS = 4000
    RRF_K = 60
    # Ranking reads the whole tsvector of every match, so a word found in
    # most messages, such as "ruby", takes longer than any client waits.
    # Past this many milliseconds the semantic ranking goes on alone.
    LEXICAL_TIMEOUT = 2000

    def initialize(corpus, embedder: nil, reranker: nil, lexical_timeout: LEXICAL_TIMEOUT, log: $stderr)
      @corpus = corpus
      @embedder = embedder
      @reranker = reranker
      @lexical_timeout = lexical_timeout
      @log = log
    end

    def call(query, limit: 10, **filters)
      depth = [CANDIDATES, limit].max
      rankings = [lexical(query, depth, filters)]
      rankings << semantic(query, depth, filters) if @embedder
      rows = @corpus.rows(fuse(rankings).first([RERANK, limit].max))
      rows = rerank(query, rows) if @reranker && rows.size > 1
      rows.first(limit)
    end

    private

    def lexical(query, depth, filters)
      phrases = Bigram.phrases(query)
      return [] if phrases.empty?
      tsquery = Sequel.lit("(#{Array.new(phrases.size, "phraseto_tsquery('simple', ?)").join(' && ')})", *phrases)
      @corpus.db.transaction do
        @corpus.db.run("SET LOCAL statement_timeout = #{Integer(@lexical_timeout)}")
        @corpus.dataset(**filters)
               .where(Sequel.lit('tsv @@ ?', tsquery))
               .order(Sequel.desc(Sequel.function(:ts_rank_cd, :tsv, tsquery)), :id)
               .limit(depth)
               .select_map(:id)
      end
    rescue Sequel::DatabaseError => e
      raise unless e.wrapped_exception.is_a?(PG::QueryCanceled)
      @log.puts "full-text search skipped after #{@lexical_timeout}ms"
      []
    end

    # Without iterative scans, the index stops after hnsw.ef_search (40)
    # rows, before the list and date filters are applied.
    def semantic(query, depth, filters)
      vector = DB.vector(@embedder.embed([query], input_type: 'search_query').first)
      @corpus.db.transaction do
        @corpus.db.run('SET LOCAL hnsw.iterative_scan = strict_order')
        @corpus.dataset(**filters)
               .exclude(embedding: nil)
               .order(Sequel.lit('embedding <=> ?::vector', vector))
               .limit(depth)
               .select_map(:id)
      end
    rescue Inference::Error => e
      @log.puts "semantic search skipped: #{e.message}"
      []
    end

    def fuse(rankings)
      scores = Hash.new(0.0)
      rankings.each do |ids|
        ids.each.with_index(1) { |id, rank| scores[id] += 1.0 / (RRF_K + rank) }
      end
      scores.sort_by { |id, score| [-score, id] }.map(&:first)
    end

    def rerank(query, rows)
      documents = rows.map { |row| @corpus.document(row)[0, RERANK_CHARS] }
      @reranker.rerank(query, documents).map { |index, _score| rows[index] }
    rescue Inference::Error => e
      @log.puts "rerank skipped: #{e.message}"
      rows
    end
  end
end
