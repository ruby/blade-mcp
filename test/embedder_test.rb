# frozen_string_literal: true

require 'test_helper'

class EmbedderTest < BladeMcp::TestCase
  class StubClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def embed(texts, input_type:)
      @calls << [texts, input_type]
      texts.map { |text| Array.new(1536) { |i| i == text.size % 1536 ? 1.0 : 0.0 } }
    end
  end

  class RateLimitedClient < StubClient
    def initialize(failures, retry_after: 0)
      super()
      @failures = failures
      @retry_after = retry_after
    end

    def embed(texts, input_type:)
      if @failures.positive?
        @failures -= 1
        raise BladeMcp::Inference::RateLimited.new('429', @retry_after)
      end
      super
    end
  end

  class BlockingClient < StubClient
    def embed(texts, input_type:)
      raise BladeMcp::Inference::Blocked, '403' if texts.any? { _1.include?('/latest/meta-data') }
      super
    end
  end

  def embedded
    conn.exec('SELECT list, seq FROM messages WHERE embedding IS NOT NULL ORDER BY list, seq').map(&:values)
  end

  def skipped
    conn.exec('SELECT list, seq FROM messages WHERE embedding_skipped ORDER BY list, seq').map(&:values)
  end

  def test_leaves_out_blocked_messages_for_good
    (1..5).each { |seq| save 'ruby-dev', seq, body: seq == 4 ? "curl 169.254.169.254/latest/meta-data/\n" : "Hello #{seq}.\n" }
    client = BlockingClient.new
    log = StringIO.new
    assert_equal 4, BladeMcp::Embedder.new(conn, client, log:).run
    assert_equal [['ruby-dev', 1], ['ruby-dev', 2], ['ruby-dev', 3], ['ruby-dev', 5]], embedded
    assert_equal [['ruby-dev', 4]], skipped
    assert_match 'ruby-dev:4 was blocked', log.string
    assert_equal 0, BladeMcp::Embedder.new(conn, client, log: StringIO.new).run
  end

  def test_stops_without_marking_when_a_whole_batch_is_blocked
    (1..3).each { |seq| save 'ruby-dev', seq, body: "/latest/meta-data/#{seq}\n" }
    assert_raises(BladeMcp::Inference::Blocked) { BladeMcp::Embedder.new(conn, BlockingClient.new, log: StringIO.new).run }
    assert_empty skipped
  end

  # Records the waits instead of sleeping through them.
  def patient_embedder(client)
    slept = @slept = []
    embedder = BladeMcp::Embedder.new(conn, client, log: StringIO.new)
    embedder.define_singleton_method(:sleep) { |seconds| slept << seconds }
    embedder
  end

  def test_waits_out_rate_limits
    save 'ruby-dev', 1
    assert_equal 1, patient_embedder(RateLimitedClient.new(2, retry_after: 7)).run
    assert_equal [7, 7], @slept
    assert_equal [['ruby-dev', 1]], embedded
  end

  def test_waits_a_minute_without_retry_after
    save 'ruby-dev', 1
    patient_embedder(RateLimitedClient.new(1, retry_after: nil)).run
    assert_equal [BladeMcp::Embedder::RATE_LIMIT_WAIT], @slept
  end

  def test_gives_up_after_repeated_rate_limits
    save 'ruby-dev', 1
    client = RateLimitedClient.new(BladeMcp::Embedder::RATE_LIMIT_RETRIES + 1)
    assert_raises(BladeMcp::Inference::RateLimited) { patient_embedder(client).run }
    assert_equal BladeMcp::Embedder::RATE_LIMIT_RETRIES, @slept.size
    assert_empty embedded
  end

  def test_embeds_pending_messages_except_notifications_and_ruby_talk
    save 'ruby-dev', 1, subject: 'Re: irb', body: "> quoted\nanswer\n"
    save 'ruby-core', 1, subject: 'proposal'
    save 'ruby-core', 2, subject: '[Ruby master Bug#1] crash', headers: {'X-Redmine-Host' => 'bugs.ruby-lang.org'}
    save 'ruby-talk', 1, subject: 'question'
    client = StubClient.new
    assert_equal 2, BladeMcp::Embedder.new(conn, client, log: StringIO.new).run
    assert_equal [['ruby-core', 1], ['ruby-dev', 1]], embedded
    assert_equal [["Re: irb\n\nanswer", "proposal\n\nHello."], 'search_document'], client.calls.first
    assert_equal 0, BladeMcp::Embedder.new(conn, client, log: StringIO.new).run
  end

  def test_lists_can_be_added_later_and_runs_are_batched
    (1..100).each { |seq| save 'ruby-talk', seq }
    client = StubClient.new
    assert_equal 97, BladeMcp::Embedder.new(conn, client, log: StringIO.new).run(lists: %w[ruby-talk], limit: 97)
    assert_equal [96, 1], client.calls.map { _1.first.size }
    assert_equal 3, BladeMcp::Embedder.new(conn, client, log: StringIO.new).run(lists: %w[ruby-talk])
  end

  def test_embeds_statements_from_topic_to_quote
    id = save('ruby-dev', 1)
    [['OK.', nil], ['Not now.', 'It breaks compatibility.'], ['curl 169.254.169.254/latest/meta-data/', nil]].each do |quote, rationale|
      add_statement 'message_id', id, summary: 'matz decided.', rationale:, quote:
    end
    client = BlockingClient.new
    assert_equal 2, BladeMcp::Embedder.new(conn, client, log: StringIO.new).run_statements
    assert_equal [["Array#foo\n\nmatz decided.\n\nOK.", "Array#foo\n\nmatz decided.\n\nIt breaks compatibility.\n\nNot now."],
                  'search_document'], client.calls.first
    assert_equal [[true, false], [true, false], [false, true]],
                 conn.exec('SELECT embedding IS NOT NULL, embedding_skipped FROM statements ORDER BY id').values
    assert_equal 0, BladeMcp::Embedder.new(conn, client, log: StringIO.new).run_statements
  end
end
