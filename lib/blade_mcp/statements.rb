# frozen_string_literal: true

require_relative 'bigram'
require_relative 'db'

module BladeMcp
  # The statements extracted from what matz wrote or was reported to have
  # said, in mails, bugs.ruby-lang.org comments and developers' meeting notes,
  # searched as a corpus of their own.
  class Statements
    KINDS = %w[accepted rejected design naming policy opinion undecided condition principle].freeze

    def self.document(row)
      row.values_at(:topic, :summary, :rationale, :quote).compact.join("\n\n")
    end

    attr_reader :db

    def initialize(db)
      @db = db
    end

    # column is :message_id, :journal_id or :meeting_item_id, the source the
    # statement came from.
    def insert(column, id, statement, date:, reported:, model:)
      s = statement
      tsv = Sequel.lit("setweight(to_tsvector('simple', ?), 'A') || setweight(to_tsvector('simple', ?), 'B') || " \
                       "setweight(to_tsvector('simple', ?), 'C')",
                       Bigram.expand([s[:topic], *s[:features]].join(' ')),
                       Bigram.expand([s[:summary], s[:rationale]].compact.join(' ')), Bigram.expand(s[:quote]))
      @db[:statements].insert(column => id, date:, kind: s[:kind], topic: s[:topic], summary: s[:summary],
                              rationale: s[:rationale], quote: s[:quote], features: Sequel.pg_array(s[:features], :text),
                              reported:, model:, tsv:)
    end

    # The statements Search ranks, narrowed by its filters.
    def dataset(kinds: nil, feature: nil, since: nil, before: nil, include_reported: true)
      ds = @db[:statements]
      ds = ds.where(kind: kinds) if kinds
      if feature
        pattern = DB.contains(feature)
        ds = ds.where(Sequel.ilike(:topic, pattern) |
                      @db.from(Sequel.function(:unnest, :features).as(:f)).where(Sequel.ilike(:f, pattern)).exists)
      end
      ds = ds.where(Sequel[:date] >= since) if since
      ds = ds.where(Sequel[:date] < before) if before
      ds = ds.where(reported: false) unless include_reported
      ds
    end

    def rows(ids)
      s = Sequel[:s]
      m = Sequel[:m]
      n = Sequel[:n]
      i = Sequel[:i]
      rows = @db.from(Sequel[:statements].as(:s))
                .left_join(Sequel[:messages].as(:m), m[:id] => s[:message_id])
                .left_join(Sequel[:redmine_notes].as(:n), n[:journal_id] => s[:journal_id])
                .left_join(Sequel[:meeting_items].as(:i), i[:id] => s[:meeting_item_id])
                .select(s[:id], s[:kind], s[:topic], s[:summary], s[:rationale], s[:quote], s[:features], s[:date],
                        s[:reported], m[:list], m[:seq], Sequel.function(:coalesce, n[:issue_id], i[:issue_id]).as(:issue_id),
                        n[:note_number], n[:author_name], i[:path].as(:meeting), i[:heading].as(:agenda))
                .where(s[:id] => ids)
                .all
      rows.sort_by { |row| ids.index(row[:id]) }
    end

    def document(row) = self.class.document(row)

    # Returns the oldest matching statements and how many match in all.
    def timeline(limit:, **filters)
      found = dataset(**filters).select(:id, Sequel.function(:count).*.over.as(:total)).order(:date, :id).limit(limit).all
      [rows(found.map { |row| row[:id] }), found.first&.fetch(:total) || 0]
    end
  end
end
