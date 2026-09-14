# frozen_string_literal: true

ENV['RACK_ENV'] = 'test'
# Never DATABASE_URL, which may point at the development database.
ENV['DATABASE_URL'] = ENV.fetch('TEST_DATABASE_URL', 'postgres://postgres@localhost/blade_mcp_test')

require 'minitest/autorun'
require_relative '../lib/blade_mcp'
require_relative '../lib/blade_mcp/embedder'
require_relative '../lib/blade_mcp/extractor'
require_relative '../lib/blade_mcp/importer'
require_relative '../lib/blade_mcp/redmine'
require_relative '../lib/blade_mcp/vault'

BladeMcp::DB.current.exec('SET client_min_messages = warning')
BladeMcp::DB.current.exec('DROP TABLE IF EXISTS statements, attachments, messages, redmine_notes, sync_state')
BladeMcp::DB.migrate(BladeMcp::DB.current)

module BladeMcp
  class TestCase < Minitest::Test
    def setup
      conn.exec('TRUNCATE statements, attachments, messages, redmine_notes RESTART IDENTITY')
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

    def encoded_word(text, label = 'ISO-2022-JP')
      "=?#{label}?B?#{[text.encode('ISO-2022-JP')].pack('m0')}?="
    end

    def vector(*hot)
      DB.vector(Array.new(1536) { |i| hot.include?(i) ? 1.0 : 0.0 })
    end
  end
end
