# frozen_string_literal: true

require_relative 'bigram'
require_relative 'db'
require_relative 'text'

module BladeMcp
  class Store
    COLUMNS = %i[id list seq parent_id from_name from_address date subject body issue notification].freeze
    # Keeps long patches under the 1MB tsvector limit; positions beyond
    # 16383 are clamped by Postgres anyway.
    INDEX_LIMIT = 100_000
    THREAD_LIMIT = 500

    attr_reader :db

    def initialize(db)
      @db = db
    end

    def save(message)
      unchanged = Sequel.lit('(messages.subject, messages.body) IS NOT DISTINCT FROM (excluded.subject, excluded.body)')
      replaced = %i[msgid reply_msgids cited_list cited_seq from_name from_address date subject body issue notification tsv]
      update = replaced.to_h { |column| [column, Sequel[:excluded][column]] }.merge(
        parent_id: nil,
        embedding: Sequel.case({unchanged => Sequel[:messages][:embedding]}, nil),
        embedding_skipped: Sequel[:messages][:embedding_skipped] & unchanged,
        statements_extracted_at: Sequel.case({unchanged => Sequel[:messages][:statements_extracted_at]}, nil)
      )
      tsv = Sequel.lit("setweight(to_tsvector('simple', ?), 'A') || setweight(to_tsvector('simple', ?), 'D')",
                       Bigram.expand(message.subject), Bigram.expand(message.body.to_s[0, INDEX_LIMIT]))
      id = @db[:messages].returning(:id).insert_conflict(target: %i[list seq], update:).insert(
        list: message.list, seq: message.seq, msgid: message.msgid, reply_msgids: Sequel.pg_array(message.reply_msgids, :text),
        cited_list: message.cited_list, cited_seq: message.cited_seq, from_name: message.from_name,
        from_address: message.from_address, date: message.date, subject: message.subject, body: message.body,
        issue: message.issue, notification: message.notification, tsv:
      ).first[:id]
      @db[:attachments].where(message_id: id).delete
      @db[:attachments].multi_insert(message.attachments.each_with_index.map do |attachment, position|
        {message_id: id, position:, filename: attachment.filename, size: attachment.size, content: attachment.content}
      end)
      id
    end

    def max_seq(list)
      @db[:messages].where(list:).max(:seq)
    end

    def find(list, seq)
      @db[:messages].select(*COLUMNS).first(list:, seq:)
    end

    def rows(ids)
      @db[:messages].select(*COLUMNS).where(id: ids).all.sort_by { |row| ids.index(row[:id]) }
    end

    # The messages Search ranks, narrowed by its filters.
    def dataset(lists: nil, since: nil, before: nil, from: nil, include_notifications: false)
      ds = @db[:messages]
      ds = ds.where(list: lists) if lists
      ds = ds.where(Sequel[:date] >= since) if since
      ds = ds.where(Sequel[:date] < before) if before
      ds = ds.where(Sequel.ilike(:from_name, DB.contains(from)) | Sequel.ilike(:from_address, DB.contains(from))) if from
      ds = ds.where(notification: false) unless include_notifications
      ds
    end

    def document(row)
      Text.passage(row[:subject], row[:body])
    end

    def ref(id)
      @db[:messages].select(:list, :seq).first(id:)
    end

    def children(id)
      @db[:messages].select(:list, :seq).where(parent_id: id).order(:date, :list, :seq).all
    end

    def attachments(id)
      @db[:attachments].select(:filename, :size, :content).where(message_id: id).order(:position).all
    end

    # A parent in the same list wins over one found in another list, then
    # In-Reply-To wins over References, nearest reference first. The body
    # citation is the last resort.
    def resolve_parents
      linked = @db.dataset.with_sql_update(<<~SQL)
        WITH candidates AS (
          SELECT DISTINCT ON (m.id) m.id, p.id AS parent_id
          FROM messages m
          CROSS JOIN LATERAL unnest(m.reply_msgids) WITH ORDINALITY AS r (msgid, position)
          JOIN messages p ON p.msgid = r.msgid AND p.id <> m.id
          WHERE m.parent_id IS NULL
          ORDER BY m.id, p.list = m.list DESC, r.position, p.date, p.id
        )
        UPDATE messages SET parent_id = candidates.parent_id FROM candidates WHERE messages.id = candidates.id
      SQL
      reply = Sequel[:reply]
      cited = Sequel[:cited]
      linked + @db.from(Sequel[:messages].as(:reply), Sequel[:messages].as(:cited))
                  .where(reply[:parent_id] => nil, cited[:list] => reply[:cited_list], cited[:seq] => reply[:cited_seq])
                  .exclude(cited[:id] => reply[:id])
                  .update(parent_id: cited[:id])
    end

    def thread(id)
      root = @db.fetch(<<~SQL, id).single_value
        WITH RECURSIVE up (id, parent_id, depth) AS (
          SELECT id, parent_id, 0 FROM messages WHERE id = ?
          UNION ALL
          SELECT m.id, m.parent_id, up.depth + 1 FROM messages m JOIN up ON m.id = up.parent_id WHERE up.depth < 100
        )
        SELECT id FROM up ORDER BY depth DESC LIMIT 1
      SQL
      @db.fetch(<<~SQL, root, THREAD_LIMIT + 1).all
        WITH RECURSIVE down (id, depth, path) AS (
          SELECT id, 0, ARRAY[id] FROM messages WHERE id = ?
          UNION ALL
          SELECT m.id, down.depth + 1, down.path || m.id
          FROM messages m JOIN down ON m.parent_id = down.id
          WHERE m.id <> ALL (down.path)
        )
        SELECT m.list, m.seq, m.from_name, m.from_address, m.date, m.subject, m.issue, m.notification, down.depth,
               p.list AS parent_list, p.seq AS parent_seq
        FROM down
        JOIN messages m ON m.id = down.id
        LEFT JOIN messages p ON p.id = m.parent_id
        ORDER BY m.date NULLS LAST, m.list, m.seq
        LIMIT ?
      SQL
    end
  end
end
