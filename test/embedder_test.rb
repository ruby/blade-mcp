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

  def embedded
    conn.exec('SELECT list, seq FROM messages WHERE embedding IS NOT NULL ORDER BY list, seq').map(&:values)
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
end
