# frozen_string_literal: true

require 'test_helper'

class MeetingLogTest < BladeMcp::TestCase
  NOTES = <<~MD
    ---
    lang: en
    ---

    # DevMeeting-2024-01-10

    * Date: 2024-01-10
    * Attendees: matz, ko1, mame

    ## From attendees

    ### [[Feature #100]](https://bugs.ruby-lang.org/issues/100) Add Array#foo (mame)

    * Proposal to add Array#foo.

    #### Discussion

    ```ruby
    # a comment, not a heading
    [1].foo
    ```

    #### Conclusion

    * matz: accepted.

    ### [Bug #200] Nothing said

    * ok
  MD

  TITLE_ONLY = NOTES[/\A.*(?=^## From attendees)/m]

  def tarball(files)
    io = StringIO.new
    gzip = Zlib::GzipWriter.new(io)
    Gem::Package::TarWriter.new(gzip) do |tar|
      files.each do |path, text|
        tar.add_file_simple("dev-meeting-log-master/#{path}", 0o644, text.bytesize) { |file| file.write(text) }
      end
    end
    gzip.finish
    io.string
  end

  def meeting_log(url)
    BladeMcp::MeetingLog.new(conn, api: url, archive: url, raw: url, token: nil, log: StringIO.new)
  end

  def items
    conn.exec('SELECT path, position, heading, issue_id, statements_extracted_at IS NOT NULL AS read FROM meeting_items ' \
              'ORDER BY path, position').map { _1.values_at('path', 'position', 'heading', 'issue_id', 'read') }
  end

  def test_items_are_split_at_headings_up_to_level_three
    headings, bodies = BladeMcp::MeetingLog.items(NOTES).transpose
    assert_equal ['DevMeeting-2024-01-10', '[[Feature #100]](https://bugs.ruby-lang.org/issues/100) Add Array#foo (mame)'],
                 headings
    assert_includes bodies[1], "# a comment, not a heading\n"
    assert_includes bodies[1], "#### Conclusion\n\n* matz: accepted.\n"
  end

  def test_dates_come_from_the_file_names
    assert_equal Date.new(2026, 7, 9), BladeMcp::MeetingLog.date('2026/DevMeeting-2026-07-09.md')
    assert_equal Date.new(2020, 5, 14), BladeMcp::MeetingLog.date('2020/DevelopersMeeting20200514Japan.md')
    assert_equal Date.new(2008, 8, 11), BladeMcp::MeetingLog.date('2008/DevCamp-08-11.md')
    assert_nil BladeMcp::MeetingLog.date('2011/Notes.md')
  end

  def test_import_reads_the_english_notes_from_a_tarball
    files = {'2024/DevMeeting-2024-01-10.md' => NOTES, '2008/DevMeeting-2008-02-15-JA.md' => NOTES, 'README.md' => NOTES,
             '2011/Notes.md' => NOTES}
    routes = {'/repos/ruby/dev-meeting-log/commits/master' => '{"sha":"c1"}', '/ruby/dev-meeting-log/tar.gz/c1' => tarball(files)}
    serve(routes) { |url| assert_equal 2, meeting_log(url).import }
    assert_equal [['2024/DevMeeting-2024-01-10.md', 0, 'DevMeeting-2024-01-10', nil, false],
                  ['2024/DevMeeting-2024-01-10.md', 1, '[[Feature #100]](https://bugs.ruby-lang.org/issues/100) Add Array#foo (mame)', 100, false]],
                 items
    assert_equal 'c1', conn.exec("SELECT value FROM sync_state WHERE name = 'meeting_log_commit'").getvalue(0, 0)
  end

  def test_sync_reads_only_the_notes_changed_since_the_last_commit
    files = {'2024/DevMeeting-2024-01-10.md' => NOTES, '2023/DevMeeting-2023-12-20.md' => NOTES,
             '2023/DevMeeting-2023-11-15.md' => NOTES, '2024/DevMeeting-2024-03-13.md' => NOTES}
    serve('/repos/ruby/dev-meeting-log/commits/master' => '{"sha":"c1"}', '/ruby/dev-meeting-log/tar.gz/c1' => tarball(files)) do |url|
      meeting_log(url).import
    end
    conn.exec('UPDATE meeting_items SET statements_extracted_at = now()')
    compare = JSON.generate(files: [
      {filename: '2024/DevMeeting-2024-01-10.md', status: 'modified'},
      {filename: '2024/DevMeeting-2024-02-14.md', status: 'added'},
      {filename: '2023/DevMeeting-2023-12-20.md', status: 'removed'},
      {filename: '2023/DevMeeting-2023-11-16.md', previous_filename: '2023/DevMeeting-2023-11-15.md', status: 'renamed'},
      {filename: '2024/DevMeeting-2024-03-13.md', status: 'modified'},
      {filename: 'README.md', status: 'modified'}
    ])
    routes = {
      '/repos/ruby/dev-meeting-log/commits/master' => '{"sha":"c2"}',
      '/repos/ruby/dev-meeting-log/compare/c1...c2' => compare,
      '/ruby/dev-meeting-log/c2/2024/DevMeeting-2024-01-10.md' => NOTES.sub('matz: accepted.', 'matz: accepted, named foo.'),
      '/ruby/dev-meeting-log/c2/2024/DevMeeting-2024-02-14.md' => "# DevMeeting-2024-02-14\n\n* matz: no meeting next month.\n",
      '/ruby/dev-meeting-log/c2/2023/DevMeeting-2023-11-16.md' => NOTES,
      '/ruby/dev-meeting-log/c2/2024/DevMeeting-2024-03-13.md' => TITLE_ONLY
    }
    serve(routes) { |url| assert_equal 5, meeting_log(url).sync }
    feature = '[[Feature #100]](https://bugs.ruby-lang.org/issues/100) Add Array#foo (mame)'
    assert_equal [['2023/DevMeeting-2023-11-16.md', 0, 'DevMeeting-2024-01-10', nil, false],
                  ['2023/DevMeeting-2023-11-16.md', 1, feature, 100, false],
                  ['2024/DevMeeting-2024-01-10.md', 0, 'DevMeeting-2024-01-10', nil, true],
                  ['2024/DevMeeting-2024-01-10.md', 1, feature, 100, false],
                  ['2024/DevMeeting-2024-02-14.md', 0, 'DevMeeting-2024-02-14', nil, false],
                  ['2024/DevMeeting-2024-03-13.md', 0, 'DevMeeting-2024-01-10', nil, true]],
                 items
    assert_equal 'c2', conn.exec("SELECT value FROM sync_state WHERE name = 'meeting_log_commit'").getvalue(0, 0)
  end

  def test_sync_needs_an_import_first
    assert_raises(RuntimeError) { BladeMcp::MeetingLog.new(conn, log: StringIO.new).sync }
  end
end
