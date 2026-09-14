# frozen_string_literal: true

require 'json'
require 'net/http'
require 'time'

module BladeMcp
  # Comments on bugs.ruby-lang.org that may hold a decision by matz: his own,
  # and those by others that name him, such as developer meeting notes. The
  # first import reads the Redmine database, later syncs go through the REST
  # API, which shows only what anonymous visitors can see.
  class Redmine
    URL = 'https://bugs.ruby-lang.org'
    USER_AGENT = 'blade-mcp (https://github.com/ruby/blade-mcp)'
    MATZ = 'matz'
    # A comment written just before the last sync may be committed after it.
    OVERLAP = 3600
    PAGE = 100

    mention = '\mmatz\M'
    # Mirrors what an anonymous visitor sees: public projects that are active
    # or closed, with the issue tracker enabled, and no private issues or
    # notes. note_number counts every journal, as Redmine's #note-N does.
    NOTES_SQL = <<~SQL.freeze
      SELECT j.id AS journal_id, i.id AS issue_id, n.note_number, p.name AS project, t.name AS tracker,
             i.subject AS issue_subject, i.description AS issue_description,
             u.login || ' (' || trim(u.firstname || ' ' || u.lastname) || ')' AS author_name,
             coalesce(u.login = '#{MATZ}', false) AS by_matz, j.created_on AT TIME ZONE 'UTC' AS created_on, j.notes,
             previous.author_name AS previous_author, previous.notes AS previous_notes
      FROM journals j
      JOIN issues i ON i.id = j.journalized_id
      JOIN projects p ON p.id = i.project_id
      JOIN trackers t ON t.id = i.tracker_id
      LEFT JOIN users u ON u.id = j.user_id
      CROSS JOIN LATERAL (
        SELECT count(*) AS note_number FROM journals o
        WHERE o.journalized_type = 'Issue' AND o.journalized_id = j.journalized_id AND (o.created_on, o.id) <= (j.created_on, j.id)
      ) n
      LEFT JOIN LATERAL (
        SELECT pu.login || ' (' || trim(pu.firstname || ' ' || pu.lastname) || ')' AS author_name, o.notes
        FROM journals o LEFT JOIN users pu ON pu.id = o.user_id
        WHERE o.journalized_type = 'Issue' AND o.journalized_id = j.journalized_id AND (o.created_on, o.id) < (j.created_on, j.id)
          AND coalesce(o.notes, '') <> '' AND NOT o.private_notes
        ORDER BY o.created_on DESC, o.id DESC
        LIMIT 1
      ) previous ON true
      WHERE j.journalized_type = 'Issue' AND coalesce(j.notes, '') <> '' AND NOT j.private_notes
        AND (u.login = '#{MATZ}' OR j.notes ~* '#{mention}')
        AND p.is_public AND p.status IN (1, 5) AND NOT i.is_private
        AND EXISTS (SELECT 1 FROM enabled_modules m WHERE m.project_id = p.id AND m.name = 'issue_tracking')
      ORDER BY j.id
    SQL

    def initialize(conn, url: URL, log: $stdout)
      @conn = conn
      @url = url
      @log = log
    end

    def import(bugs)
      rows = bugs.transaction do
        bugs.exec('SET TRANSACTION READ ONLY')
        [bugs.exec('SELECT now()').getvalue(0, 0), bugs.exec(NOTES_SQL).to_a]
      end
      checked_at, notes = rows
      @conn.transaction do
        notes.each { |note| save(note) }
        checked!(checked_at)
      end
      @log.puts "imported #{notes.size} comments from bugs.ruby-lang.org"
      notes.size
    end

    def sync
      checked_at = @conn.exec("SELECT value FROM sync_state WHERE name = 'redmine_checked_at'").first&.fetch('value')
      raise 'run import-redmine before syncing' unless checked_at
      started = Time.now.utc
      since = (Time.iso8601(checked_at) - OVERLAP).utc.iso8601
      notes = updated_issue_ids(since).flat_map { |id| issue_notes(id) }
      @conn.transaction do
        notes.each { |note| save(note) }
        checked!(started)
      end
      @log.puts "synced #{notes.size} comments from bugs.ruby-lang.org"
      notes.size
    end

    private

    def save(note)
      columns = %w[journal_id issue_id note_number project tracker issue_subject issue_description author_name by_matz
                   created_on notes previous_author previous_notes]
      @conn.exec_params(<<~SQL, note.values_at(*columns))
        INSERT INTO redmine_notes (#{columns.join(', ')}) VALUES (#{columns.each_index.map { |i| "$#{i + 1}" }.join(', ')})
        ON CONFLICT (journal_id) DO UPDATE SET #{columns.drop(1).map { |c| "#{c} = EXCLUDED.#{c}" }.join(', ')},
          statements_extracted_at = CASE WHEN redmine_notes.notes = EXCLUDED.notes THEN redmine_notes.statements_extracted_at END
      SQL
    end

    def checked!(time)
      @conn.exec_params(<<~SQL, [time.utc.iso8601])
        INSERT INTO sync_state (name, value) VALUES ('redmine_checked_at', $1)
        ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value
      SQL
    end

    def updated_issue_ids(since)
      ids = []
      loop do
        page = get('/issues.json', status_id: '*', updated_on: ">=#{since}", sort: 'updated_on', limit: PAGE, offset: ids.size)
        ids.concat(page.fetch('issues').map { |issue| issue['id'] })
        break if page['issues'].empty? || ids.size >= page.fetch('total_count')
      end
      ids
    end

    def issue_notes(id)
      issue = get("/issues/#{id}.json", include: 'journals').fetch('issue')
      previous = nil
      issue.fetch('journals').each.with_index(1).filter_map do |journal, number|
        notes = journal['notes'].to_s
        next if notes.empty? || journal['private_notes']
        author = journal.dig('user', 'name')
        by_matz = author.to_s.split(' (').first == MATZ
        note = {
          'journal_id' => journal['id'], 'issue_id' => issue['id'], 'note_number' => number,
          'project' => issue.dig('project', 'name'), 'tracker' => issue.dig('tracker', 'name'),
          'issue_subject' => issue['subject'], 'issue_description' => issue['description'], 'author_name' => author,
          'by_matz' => by_matz, 'created_on' => Time.iso8601(journal['created_on']), 'notes' => notes,
          'previous_author' => previous&.dig('user', 'name'), 'previous_notes' => previous&.fetch('notes')
        }
        previous = journal
        note if by_matz || notes.match?(/\bmatz\b/i)
      end
    end

    def get(path, params)
      uri = URI("#{@url}#{path}")
      uri.query = URI.encode_www_form(params)
      response = Net::HTTP.get_response(uri, 'User-Agent' => USER_AGENT)
      raise "#{uri} returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    end
  end
end
