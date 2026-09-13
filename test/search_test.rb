# frozen_string_literal: true

require 'test_helper'

class SearchTest < BladeMcp::TestCase
  class StubEmbedder
    def initialize(vector = nil, &block)
      @vector = vector
      @block = block
    end

    def embed(texts, input_type:)
      raise ArgumentError unless input_type == 'search_query'
      @block&.call
      texts.map { @vector }
    end
  end

  class StubReranker
    attr_reader :documents

    def rerank(_query, documents)
      @documents = documents
      documents.each_index.to_a.reverse.map { [_1, 0.5] }
    end
  end

  def setup
    super
    save 'ruby-dev', 30000, subject: '[ruby-dev:30000] lib/irb/locale.rb uses File.exists?',
                            content_type: 'text/plain; charset=ISO-2022-JP',
                            body: "金本ともうします。\n1.9のirbでおこられました。\n".encode('ISO-2022-JP')
    save 'ruby-dev', 30001, subject: '[ruby-dev:30001] Re: おこられ', date: 'Sun, 10 Dec 2006 10:00:00 +0900',
                            body: "> 1.9のirbでおこられました。\n直しました。\n"
    save 'ruby-core', 10000, subject: 'Re: new method dispatch rule', body: "The method dispatch proposal by matz.\n"
    save 'ruby-core', 120000, subject: '[ruby-core:120000] [Ruby master Feature#20861] thread quantum',
                              headers: {'X-Redmine-Host' => 'bugs.ruby-lang.org'}
  end

  def refs(rows)
    rows.map { |row| "#{row['list']}:#{row['seq']}" }
  end

  def search(query, embedder: nil, reranker: nil, **filters)
    refs(BladeMcp::Search.new(store, embedder:, reranker:, log: StringIO.new).call(query, **filters))
  end

  def test_japanese_phrases_match_as_written
    assert_equal %w[ruby-dev:30000], search('金本')
    assert_equal %w[ruby-dev:30001 ruby-dev:30000], search('おこられ')
    assert_empty search('おこらない')
  end

  def test_english_words_all_have_to_match
    assert_equal %w[ruby-dev:30000], search('File.exists')
    assert_equal %w[ruby-core:10000], search('dispatch matz')
    assert_empty search('dispatch irb')
    assert_empty search('"matz dispatch"')
  end

  def test_filters
    assert_equal %w[ruby-dev:30000], search('irb', lists: %w[ruby-dev], before: Time.utc(2006, 12, 9))
    assert_equal %w[ruby-dev:30001], search('irb', since: Time.utc(2006, 12, 9, 12))
    assert_empty search('irb', lists: %w[ruby-core])
  end

  def test_notifications_are_left_out_unless_asked_for
    assert_empty search('quantum')
    assert_equal %w[ruby-core:120000], search('quantum', include_notifications: true)
  end

  def test_semantic_matches_are_fused_with_full_text_ones
    ids = %w[30000 30001].to_h { [_1, store.find('ruby-dev', _1.to_i)['id']] }
    conn.exec_params('UPDATE messages SET embedding = $2::vector WHERE id = $1', [ids['30000'], vector(0)])
    conn.exec_params('UPDATE messages SET embedding = $2::vector WHERE id = $1', [ids['30001'], vector(1)])
    embedder = StubEmbedder.new([1.0] + Array.new(1535, 0.0))
    assert_equal %w[ruby-dev:30000], search('金本')
    assert_equal %w[ruby-dev:30000 ruby-dev:30001], search('金本', embedder:)
    assert_equal %w[ruby-dev:30001], search('金本', embedder:, lists: %w[ruby-dev], since: Time.utc(2006, 12, 9, 12))
  end

  def test_rerank_orders_the_fused_candidates
    reranker = StubReranker.new
    assert_equal %w[ruby-dev:30000 ruby-dev:30001], search('おこられ', reranker:)
    assert_equal "[ruby-dev:30001] Re: おこられ\n\n直しました。", reranker.documents.first
  end

  def test_rerank_documents_are_cut_to_rerank_chars
    [1, 2].each { |seq| save 'ruby-list', seq, subject: 'long', body: "patch #{'long ' * 1000}\n" }
    reranker = StubReranker.new
    search('patch', reranker:, lists: %w[ruby-list])
    assert_equal [BladeMcp::Search::RERANK_CHARS] * 2, reranker.documents.map(&:size)
  end

  def test_limit_above_the_rerank_window_returns_more
    (1..50).each { |seq| save 'ruby-list', seq, subject: "matz #{seq}" }
    assert_equal 10, search('matz').size
    assert_equal 45, search('matz', limit: 45).size
  end

  def test_inference_failures_fall_back_to_full_text
    embedder = StubEmbedder.new { raise BladeMcp::Inference::Error, 'down' }
    assert_equal %w[ruby-dev:30000], search('金本', embedder:)
  end
end
