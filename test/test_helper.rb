# frozen_string_literal: true

ENV['RACK_ENV'] = 'test'
# Never DATABASE_URL, which may point at the development database.
ENV['DATABASE_URL'] = ENV.fetch('TEST_DATABASE_URL', 'postgres://postgres@localhost/blade_mcp_test')

require 'minitest/autorun'
require_relative '../lib/blade_mcp'
require_relative '../lib/blade_mcp/embedder'
require_relative '../lib/blade_mcp/extractor'
require_relative '../lib/blade_mcp/importer'
require_relative '../lib/blade_mcp/meeting_log'
require_relative '../lib/blade_mcp/redmine'
require_relative '../lib/blade_mcp/vault'
require 'socket'

BladeMcp::DB.current.exec('SET client_min_messages = warning')
BladeMcp::DB.current.exec('DROP TABLE IF EXISTS statements, attachments, messages, redmine_notes, meeting_items, ' \
                          'sync_state, schema_migrations')
BladeMcp::DB.migrate

module BladeMcp
  class TestCase < Minitest::Test
    def setup
      conn.exec('TRUNCATE statements, attachments, messages, redmine_notes, meeting_items, sync_state RESTART IDENTITY')
    end

    # Serves the body given for each path, calling it with the request target
    # when it is a lambda, and returns the targets requested.
    def serve(routes)
      server = TCPServer.new('127.0.0.1', 0)
      requested = []
      thread = Thread.new do
        loop do
          socket = server.accept
          target = socket.gets.split[1]
          socket.gets("\r\n\r\n")
          requested << target
          body = routes.fetch(target.split('?').first) { |path| raise "unexpected #{path}" }
          body = body.call(target) if body.respond_to?(:call)
          socket.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
          socket.close
        end
      rescue IOError
        nil
      end
      yield "http://127.0.0.1:#{server.addr[1]}"
      requested
    ensure
      server&.close
      thread&.join
    end

    def conn
      DB.current
    end

    def store
      @store ||= Store.new(conn)
    end

    def raw_mail(subject: 'hello', from: 'Yukihiro Matsumoto <matz@ruby-lang.org>',
                 date: 'Sat, 09 Dec 2006 04:47:41 +0900', content_type: 'text/plain; charset=us-ascii',
                 headers: {}, body: "Hello.\n")
      fields = {'From' => from, 'Date' => date, 'Subject' => subject, 'Content-Type' => content_type}
      fields = fields.merge(headers).compact
      "#{fields.map { |name, value| "#{name}: #{value}" }.join("\n")}\n\n".b + body.b
    end

    def save(list, seq, **mail)
      store.save(Parser.parse(raw_mail(**mail), list, seq))
    end

    def add_statement(column, id, date: Time.utc(2024, 1, 3), reported: false, **fields)
      statement = {kind: 'accepted', topic: 'Array#foo', summary: 'matz accepted Array#foo.', rationale: nil,
                   quote: 'OK.', features: ['Array#foo']}.merge(fields)
      Statements.new(conn).insert(column, id, statement, date:, reported:, model: 'stub')
    end

    def add_note(journal_id, issue_id: 100, note_number: 1, author_name: 'matz (Yukihiro Matsumoto)', notes: 'Accepted.')
      conn.exec_params(<<~SQL, [journal_id, issue_id, note_number, author_name, author_name.start_with?('matz '), notes])
        INSERT INTO redmine_notes (journal_id, issue_id, note_number, project, tracker, issue_subject, author_name,
                                   by_matz, created_on, notes)
        VALUES ($1, $2, $3, 'Ruby', 'Feature', 'Add Array#foo', $4, $5, '2024-01-03 00:00:00Z', $6)
      SQL
    end

    def add_meeting_item(path: '2024/DevMeeting-2024-02-01.md', heading: '[[Feature #100]](https://bugs.ruby-lang.org/issues/100) Add Array#foo (mame)',
                         body: "* matz: accepted.\n", issue_id: 100)
      conn.exec_params(<<~SQL, [path, heading, body, issue_id, MeetingLog.date(path)]).getvalue(0, 0)
        INSERT INTO meeting_items (path, position, date, heading, body, issue_id) VALUES ($1, 0, $5, $2, $3, $4) RETURNING id
      SQL
    end

    def encoded_word(text, label = 'ISO-2022-JP')
      "=?#{label}?B?#{[text.encode('ISO-2022-JP')].pack('m0')}?="
    end

    def vector(*hot)
      DB.vector(Array.new(1536) { |i| hot.include?(i) ? 1.0 : 0.0 })
    end
  end
end
