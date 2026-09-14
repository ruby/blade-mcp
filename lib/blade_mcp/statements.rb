# frozen_string_literal: true

require_relative 'bigram'
require_relative 'db'

module BladeMcp
  # The statements extracted from what matz wrote or was reported to have
  # said, searched as a corpus of their own.
  class Statements
    KINDS = %w[accepted rejected design naming policy opinion undecided condition principle].freeze
    COLUMNS = 's.id, s.kind, s.topic, s.summary, s.rationale, s.quote, s.features, s.date, s.reported, ' \
              'm.list, m.seq, n.issue_id, n.note_number, n.author_name'

    def self.document(row)
      row.values_at('topic', 'summary', 'rationale', 'quote').compact.join("\n\n")
    end

    attr_reader :conn

    def initialize(conn)
      @conn = conn
    end

    # column is message_id or journal_id, the source the statement came from.
    def insert(column, id, statement, date:, reported:, model:)
      s = statement
      params = [id, date, s[:kind], s[:topic], s[:summary], s[:rationale], s[:quote], s[:features], reported, model,
                Bigram.expand([s[:topic], *s[:features]].join(' ')),
                Bigram.expand([s[:summary], s[:rationale]].compact.join(' ')), Bigram.expand(s[:quote])]
      @conn.exec_params(<<~SQL, params).getvalue(0, 0)
        INSERT INTO statements (#{column}, date, kind, topic, summary, rationale, quote, features, reported, model, tsv)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8::text[], $9, $10,
                setweight(to_tsvector('simple', $11), 'A') || setweight(to_tsvector('simple', $12), 'B') ||
                setweight(to_tsvector('simple', $13), 'C'))
        RETURNING id
      SQL
    end

    def table = 'statements'

    def conditions(params, kinds: nil, feature: nil, since: nil, before: nil, include_reported: true)
      sql = []
      sql << "kind = ANY($#{params.push(kinds).size}::text[])" if kinds
      if feature
        n = params.push(DB.contains(feature)).size
        sql << "(topic ILIKE $#{n} OR EXISTS (SELECT FROM unnest(features) AS f WHERE f ILIKE $#{n}))"
      end
      sql << "date >= $#{params.push(since).size}" if since
      sql << "date < $#{params.push(before).size}" if before
      sql << 'NOT reported' unless include_reported
      sql
    end

    def rows(ids)
      rows = @conn.exec_params(<<~SQL, [ids]).to_a
        SELECT #{COLUMNS}
        FROM statements s
        LEFT JOIN messages m ON m.id = s.message_id
        LEFT JOIN redmine_notes n ON n.journal_id = s.journal_id
        WHERE s.id = ANY($1::bigint[])
      SQL
      rows.sort_by { |row| ids.index(row['id']) }
    end

    def document(row) = self.class.document(row)

    # Returns the oldest matching statements and how many match in all.
    def timeline(limit:, **filters)
      params = []
      where = conditions(params, **filters)
      found = @conn.exec_params(<<~SQL, params).to_a
        SELECT id, count(*) OVER () AS total FROM statements
        #{"WHERE #{where.join(' AND ')}" if where.any?}
        ORDER BY date, id
        LIMIT #{Integer(limit)}
      SQL
      [rows(found.map { |row| row['id'] }), found.first&.fetch('total') || 0]
    end
  end
end
