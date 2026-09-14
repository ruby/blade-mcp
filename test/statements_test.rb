# frozen_string_literal: true

require 'test_helper'

class StatementsTest < BladeMcp::TestCase
  class StubEmbedder
    def initialize(vector)
      @vector = vector
    end

    def embed(texts, input_type:)
      texts.map { @vector }
    end
  end

  def setup
    super
    mail = save('ruby-dev', 1, subject: 'Re: Ractor')
    add_note 7, issue_id: 100, note_number: 3, author_name: 'ko1 (Koichi Sasada)', notes: 'matz: accepted.'
    @ids = {
      design: add_statement(:message_id, mail, date: Time.utc(2020, 1, 1), kind: 'design', topic: 'Ractor isolation',
                                                summary: 'matz does not share objects between Ractors.',
                                                quote: 'Ractor 間でオブジェクトは共有しない', features: %w[Ractor]),
      accepted: add_statement(:journal_id, 7, date: Time.utc(2024, 1, 3), reported: true, topic: 'Ractor::Port',
                                               summary: 'matz accepted Ractor::Port.', quote: 'matz: accepted.',
                                               features: %w[Ractor::Port]),
      naming: add_statement(:message_id, mail, date: Time.utc(2018, 1, 1), kind: 'naming',
                                                topic: 'then as an alias of yield_self', summary: 'matz chose then.',
                                                quote: 'then にします', features: %w[Kernel#then])
    }
  end

  def statements
    BladeMcp::Statements.new(db)
  end

  def search(query, embedder: nil, **filters)
    rows = BladeMcp::Search.new(statements, embedder:, log: StringIO.new).call(query, **filters)
    rows.map { |row| @ids.key(row[:id]) }
  end

  def test_search_by_words_and_filters
    assert_equal %i[design accepted], search('Ractor').sort_by { @ids[_1] }
    assert_equal %i[design], search('共有')
    assert_equal %i[design], search('Ractor', kinds: %w[design naming])
    assert_equal %i[design], search('Ractor', include_reported: false)
    assert_equal %i[accepted], search('Ractor', since: Time.utc(2021, 1, 1))
    assert_equal %i[design], search('Ractor', before: Time.utc(2021, 1, 1))
  end

  def test_feature_matches_part_of_the_topic_or_a_feature_ignoring_case
    assert_equal %i[design accepted], search('matz', feature: 'RACTOR').sort_by { @ids[_1] }
    assert_equal %i[naming], search('matz', feature: 'kernel#')
    assert_empty search('matz', feature: 'JIT')
  end

  def test_semantic_matches_are_filtered_too
    db[:statements].update(embedding: vector(0))
    embedder = StubEmbedder.new([1.0] + Array.new(1535, 0.0))
    assert_equal %i[design accepted naming], search('isolation of parallel execution', embedder:).sort_by { @ids[_1] }
    assert_equal %i[naming], search('isolation of parallel execution', embedder:, kinds: %w[naming])
  end

  def test_timeline_is_oldest_first_with_the_total
    rows, total = statements.timeline(feature: 'ractor', limit: 1)
    assert_equal 2, total
    assert_equal [@ids[:design]], rows.map { _1[:id] }
    rows, = statements.timeline(feature: 'ractor', limit: 10)
    assert_equal [['ruby-dev', 1, nil, nil, nil], [nil, nil, 100, 3, 'ko1 (Koichi Sasada)']],
                 rows.map { _1.values_at(:list, :seq, :issue_id, :note_number, :author_name) }
    assert_equal [[], 0], statements.timeline(feature: 'JIT', limit: 10)
  end
end
