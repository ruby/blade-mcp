# frozen_string_literal: true

require 'test_helper'

class ExtractorTest < BladeMcp::TestCase
  class StubChat
    attr_reader :prompts

    def initialize(&answer)
      @answer = answer
      @prompts = []
    end

    def model = 'stub-model'

    def call_tool(system, user, tool)
      raise ArgumentError unless system == BladeMcp::Extractor::SYSTEM && tool == BladeMcp::Extractor::TOOL
      @prompts << user
      [{'statements' => @answer.call(user)}, {'total_tokens' => 100}]
    end
  end

  def statement(kind: 'accepted', topic: 'Array#foo', quote: 'OK, accepted.', features: ['Array#foo'])
    {'kind' => kind, 'topic' => topic, 'summary' => 'matz accepted Array#foo.', 'rationale' => '', 'quote' => quote,
     'features' => features}
  end

  def extract(client, **options)
    BladeMcp::Extractor.new(db, client, concurrency: 2, log: StringIO.new).run(**options)
  end

  def extracted(table, key)
    db[table].exclude(statements_extracted_at: nil).order(key).select_map(key)
  end

  def note(journal_id, by_matz:, notes:)
    db[:redmine_notes].insert(journal_id:, issue_id: 100, note_number: journal_id, project: 'Ruby', tracker: 'Feature',
                              issue_subject: 'Add Array#foo', issue_description: 'I propose Array#foo.',
                              author_name: by_matz ? 'matz (Yukihiro Matsumoto)' : 'mame (Yusuke Endoh)', by_matz:,
                              created_on: Time.utc(2024, 1, 3), notes:, previous_author: 'ko1 (Koichi Sasada)',
                              previous_notes: 'Looks useful.')
  end

  def test_reads_matz_mails_with_their_parent
    save 'ruby-dev', 1, subject: 'Array#foo', from: 'Yusuke Endoh <mame@example.com>', body: "Let's add Array#foo.\n",
                        headers: {'Message-ID' => '<1@x>'}
    save 'ruby-dev', 2, subject: 'Re: Array#foo', body: "> Let's add Array#foo.\nOK, accepted.\n",
                        headers: {'Message-ID' => '<2@x>', 'In-Reply-To' => '<1@x>'}
    save 'ruby-dev', 3, subject: 'Re: Array#foo', from: 'Eye Matz <matz@example.org>', body: "Me too.\n"
    save 'ruby-core', 4, subject: '[Ruby master Feature#1] Array#foo', headers: {'X-Redmine-Host' => 'bugs.ruby-lang.org'}
    store.resolve_parents
    client = StubChat.new { [statement, statement(kind: 'wish')] }
    assert_equal 1, extract(client, sources: %w[ml])
    assert_equal 1, client.prompts.size
    prompt = client.prompts.first
    assert_includes prompt, "<context>\nParent post [ruby-dev:1] by Yusuke Endoh\nSubject: Array#foo\n\nLet's add Array#foo."
    assert_includes prompt, "<target>\nPost [ruby-dev:2] by Yukihiro Matsumoto (matz) on 2006-12-08\nSubject: Re: Array#foo"
    rows = db[:statements].select(:message_id, :journal_id, :kind, :topic, :rationale, :quote, :features, :reported, :model).all
    assert_equal 1, rows.size
    row = rows.first
    assert_equal [store.find('ruby-dev', 2)[:id], nil, 'accepted', 'Array#foo', nil, 'OK, accepted.', ['Array#foo'], false,
                  'stub-model'],
                 row.values_at(:message_id, :journal_id, :kind, :topic, :rationale, :quote, :features, :reported, :model)
    assert_equal [store.find('ruby-dev', 2)[:id]], extracted(:messages, :id)
    assert_equal 0, extract(StubChat.new { flunk }, sources: %w[ml])
  end

  def test_reads_redmine_comments_and_marks_what_others_reported
    note 3, by_matz: true, notes: 'Accepted.'
    note 5, by_matz: false, notes: 'matz said the name should be foo.'
    client = StubChat.new { |prompt| prompt.include?('by matz') ? [statement] : [statement(kind: 'naming', quote: 'foo')] }
    assert_equal 2, extract(client, sources: %w[redmine])
    assert_includes client.prompts.first, "Issue #100 (Feature): Add Array#foo\n\nI propose Array#foo.\n\nPrevious comment by ko1"
    assert_includes client.prompts.first, 'Comment #note-3 on issue #100 by matz (Yukihiro Matsumoto) on 2024-01-03'
    assert_equal [[3, 'accepted', false], [5, 'naming', true]],
                 db[:statements].order(:journal_id).select_map(%i[journal_id kind reported])
  end

  def test_quotes_of_matz_comments_are_cut_from_other_comments
    note 3, by_matz: false, notes: "matz (Yukihiro Matsumoto) wrote in #note-2:\n> I accept foo.\n>\n> Matz.\n\nThanks.\n\n" \
                                   "From the meeting notes:\n> * matz: foo is fine.\n"
    note 5, by_matz: true, notes: "mame (Yusuke Endoh) wrote:\n> Yukihiro Matsumoto wrote:\n> > old\n\nAccepted.\n"
    client = StubChat.new { [] }
    extract(client, sources: %w[redmine])
    assert_includes client.prompts.first, "on 2024-01-03\n\n\nThanks.\n\nFrom the meeting notes:\n> * matz: foo is fine.\n"
    refute_includes client.prompts.first, 'I accept foo.'
    assert_includes client.prompts.last, "> Yukihiro Matsumoto wrote:\n> > old\n\nAccepted."
  end

  def test_reads_meeting_notes_as_reported
    id = add_meeting_item
    client = StubChat.new { [statement(kind: 'accepted', quote: 'matz: accepted.')] }
    assert_equal 1, extract(client, sources: %w[meeting])
    assert_includes client.prompts.first, "Notes of the Ruby developers' meeting on 2024-02-01, written by the attendees " \
                                          'and kept as 2024/DevMeeting-2024-02-01.md in ruby/dev-meeting-log.'
    assert_includes client.prompts.first, "From the agenda item \"[[Feature #100]](https://bugs.ruby-lang.org/issues/100) " \
                                          "Add Array#foo (mame)\"\n\n* matz: accepted."
    assert_equal [[id, true, Time.utc(2024, 2, 1)]], db[:statements].select_map(%i[meeting_item_id reported date])
    assert_equal [id], extracted(:meeting_items, :id)
  end

  def test_blocked_text_is_not_read_again_but_failures_are
    save 'ruby-dev', 1, body: "blocked\n"
    save 'ruby-dev', 2, body: "flaky\n"
    client = StubChat.new do |prompt|
      raise BladeMcp::Inference::Blocked, '403' if prompt.include?('blocked')
      raise BladeMcp::Inference::Error, '500' if prompt.include?('flaky')
    end
    assert_equal 2, extract(client)
    assert_equal [store.find('ruby-dev', 1)[:id]], extracted(:messages, :id)
    retry_client = StubChat.new { [] }
    assert_equal 1, extract(retry_client)
    assert_equal 1, retry_client.prompts.size
    assert_includes retry_client.prompts.first, 'flaky'
  end

  def test_limit_and_a_changed_text_reads_again
    save 'ruby-dev', 1, body: "first\n"
    save 'ruby-dev', 2, body: "second\n"
    assert_equal 1, extract(StubChat.new { [statement] }, limit: 1)
    save 'ruby-dev', 1, body: "first, edited\n"
    client = StubChat.new { [statement(topic: 'edited')] }
    assert_equal 2, extract(client)
    assert_equal %w[edited edited], db[:statements].order(:message_id).select_map(:topic)
  end
end
