# frozen_string_literal: true

require 'test_helper'

class RedmineTest < BladeMcp::TestCase
  # The few Redmine tables and columns the import reads, in a schema of their own.
  BUGS_SCHEMA = <<~SQL
    DROP SCHEMA IF EXISTS bugs_fixture CASCADE;
    CREATE SCHEMA bugs_fixture;
    CREATE TABLE projects (id integer PRIMARY KEY, name text, is_public boolean, status integer);
    CREATE TABLE enabled_modules (project_id integer, name text);
    CREATE TABLE trackers (id integer PRIMARY KEY, name text);
    CREATE TABLE users (id integer PRIMARY KEY, login text, firstname text, lastname text);
    CREATE TABLE issues (id integer PRIMARY KEY, project_id integer, tracker_id integer, subject text, description text,
                         is_private boolean DEFAULT false);
    CREATE TABLE journals (id integer PRIMARY KEY, journalized_id integer, journalized_type text DEFAULT 'Issue',
                           user_id integer, notes text, private_notes boolean DEFAULT false, created_on timestamp);
    INSERT INTO projects VALUES (1, 'Ruby master', true, 1), (2, 'Private', false, 1), (3, 'Archived', true, 9);
    INSERT INTO enabled_modules VALUES (1, 'issue_tracking'), (2, 'issue_tracking'), (3, 'issue_tracking');
    INSERT INTO trackers VALUES (2, 'Feature');
    INSERT INTO users VALUES (13, 'matz', 'Yukihiro', 'Matsumoto'), (1, 'mame', 'Yusuke', 'Endoh');
    INSERT INTO issues VALUES (100, 1, 2, 'Add Array#foo', 'I propose Array#foo.'), (200, 2, 2, 'secret', ''),
                              (300, 3, 2, 'old', '');
    INSERT INTO journals (id, journalized_id, user_id, notes, private_notes, created_on) VALUES
      (1, 100, 1, 'I like it.', false, '2024-01-01 00:00:00'),
      (2, 100, 1, '', false, '2024-01-02 00:00:00'),
      (3, 100, 13, 'Accepted. Go ahead.', false, '2024-01-03 00:00:00'),
      (4, 100, 13, 'Private remark.', true, '2024-01-04 00:00:00'),
      (5, 100, 1, 'At the dev meeting, matz said the name should be foo.', false, '2024-01-05 00:00:00'),
      (6, 100, 1, 'Unrelated follow-up.', false, '2024-01-06 00:00:00'),
      (7, 200, 13, 'Hidden.', false, '2024-01-01 00:00:00'),
      (8, 300, 13, 'Archived.', false, '2024-01-01 00:00:00');
  SQL

  def bugs
    @bugs ||= BladeMcp::DB.connect(search_path: 'bugs_fixture').tap { |bugs| bugs.run(BUGS_SCHEMA) }
  end

  def teardown
    @bugs&.run('DROP SCHEMA bugs_fixture CASCADE')
    @bugs&.disconnect
  end

  def notes
    db[:redmine_notes].order(:journal_id).all
  end

  def test_import_reads_public_comments_by_or_about_matz
    assert_equal 2, BladeMcp::Redmine.new(db, log: StringIO.new).import(bugs)
    matz, meeting = notes
    assert_equal [3, 100, 3, 'Ruby master', 'Feature', 'Add Array#foo', 'I propose Array#foo.', 'matz (Yukihiro Matsumoto)',
                  true, Time.utc(2024, 1, 3), 'Accepted. Go ahead.', 'mame (Yusuke Endoh)', 'I like it.'],
                 matz.values_at(*BladeMcp::Redmine::COLUMNS)
    assert_equal [5, 5, false, 'Accepted. Go ahead.'], meeting.values_at(:journal_id, :note_number, :by_matz, :previous_notes)
    refute_nil db[:sync_state].where(name: 'redmine_checked_at').get(:value)
  end

  def test_reimport_reads_an_edited_comment_again
    redmine = BladeMcp::Redmine.new(db, log: StringIO.new)
    redmine.import(bugs)
    db[:redmine_notes].update(statements_extracted_at: Sequel::CURRENT_TIMESTAMP)
    bugs[:journals].where(id: 3).update(notes: 'Accepted, with the name foo.')
    redmine.import(bugs)
    assert_equal [[3, false], [5, true]],
                 db[:redmine_notes].order(:journal_id).select_map([:journal_id, Sequel.~(statements_extracted_at: nil).as(:read)])
  end

  def issue_json(id, journals)
    JSON.generate(issue: {id:, project: {name: 'Ruby master'}, tracker: {name: 'Feature'}, subject: 'Add Array#foo',
                          description: 'I propose Array#foo.', journals:})
  end

  def test_sync_fetches_issues_updated_since_the_last_check
    db[:sync_state].insert(name: 'redmine_checked_at', value: '2024-02-01T01:00:00Z')
    journals = [
      {id: 11, user: {name: 'mame (Yusuke Endoh)'}, notes: 'Proposal looks good.', created_on: '2024-02-01T00:00:00Z'},
      {id: 12, user: {name: 'matz (Yukihiro Matsumoto)'}, notes: '', created_on: '2024-02-01T00:30:00Z'},
      {id: 13, user: {name: 'matz (Yukihiro Matsumoto)'}, notes: 'Rejected.', created_on: '2024-02-02T00:00:00Z'},
      {id: 14, user: {name: 'mame (Yusuke Endoh)'}, notes: 'matz rejected it at the meeting.', created_on: '2024-02-03T00:00:00Z'},
      {id: 15, user: {name: 'ko1 (Koichi Sasada)'}, notes: 'Noted.', created_on: '2024-02-04T00:00:00Z'}
    ]
    pages = [JSON.generate(issues: [{id: 100}], total_count: 2), JSON.generate(issues: [{id: 101}], total_count: 2)]
    routes = {'/issues.json' => ->(_) { pages.shift }, '/issues/100.json' => issue_json(100, journals),
              '/issues/101.json' => issue_json(101, [])}
    requested = serve(routes) do |url|
      assert_equal 2, BladeMcp::Redmine.new(db, url:, log: StringIO.new).sync
    end
    assert_includes requested.first, 'updated_on=%3E%3D2024-02-01T00%3A00%3A00Z'
    refute_includes requested.first, 'sort='
    assert_includes requested[1], 'offset=1'
    assert_equal [[13, 3, true, 'Proposal looks good.'], [14, 4, false, 'Rejected.']],
                 notes.map { _1.values_at(:journal_id, :note_number, :by_matz, :previous_notes) }
    checked_at = Time.iso8601(db[:sync_state].where(name: 'redmine_checked_at').get(:value))
    assert_in_delta Time.now, checked_at, 60
  end

  def test_sync_needs_an_import_first
    assert_raises(RuntimeError) { BladeMcp::Redmine.new(db, log: StringIO.new).sync }
  end
end
