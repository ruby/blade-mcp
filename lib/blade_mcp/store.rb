# frozen_string_literal: true

require_relative 'bigram'
require_relative 'text'

module BladeMcp
  class Store
    COLUMNS = 'id, list, seq, parent_id, from_name, from_address, date, subject, body, issue, notification'
    # Keeps long patches under the 1MB tsvector limit; positions beyond
    # 16383 are clamped by Postgres anyway.
    INDEX_LIMIT = 100_000
    THREAD_LIMIT = 500

    attr_reader :conn

    def initialize(conn)
      @conn = conn
    end

    def save(message)
      params = [
        message.list, message.seq, message.msgid, message.reply_msgids, message.cited_list, message.cited_seq,
        message.from_name, message.from_address, message.date, message.subject, message.body, message.issue,
        message.notification, Bigram.expand(message.subject), Bigram.expand(message.body.to_s[0, INDEX_LIMIT])
      ]
      id = @conn.exec_params(<<~SQL, params).getvalue(0, 0)
        INSERT INTO messages (list, seq, msgid, reply_msgids, cited_list, cited_seq, from_name, from_address,
                              date, subject, body, issue, notification, tsv)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13,
                setweight(to_tsvector('simple', $14), 'A') || setweight(to_tsvector('simple', $15), 'D'))
        ON CONFLICT (list, seq) DO UPDATE SET
          msgid = EXCLUDED.msgid, reply_msgids = EXCLUDED.reply_msgids, cited_list = EXCLUDED.cited_list,
          cited_seq = EXCLUDED.cited_seq, parent_id = NULL, from_name = EXCLUDED.from_name,
          from_address = EXCLUDED.from_address, date = EXCLUDED.date, subject = EXCLUDED.subject,
          body = EXCLUDED.body, issue = EXCLUDED.issue, notification = EXCLUDED.notification, tsv = EXCLUDED.tsv,
          embedding = CASE WHEN (messages.subject, messages.body) IS NOT DISTINCT FROM (EXCLUDED.subject, EXCLUDED.body)
                           THEN messages.embedding END,
          embedding_skipped = messages.embedding_skipped AND
                              (messages.subject, messages.body) IS NOT DISTINCT FROM (EXCLUDED.subject, EXCLUDED.body),
          statements_extracted_at = CASE WHEN (messages.subject, messages.body) IS NOT DISTINCT FROM (EXCLUDED.subject, EXCLUDED.body)
                                         THEN messages.statements_extracted_at END
        RETURNING id
      SQL
      @conn.exec_params('DELETE FROM attachments WHERE message_id = $1', [id])
      message.attachments.each_with_index do |attachment, position|
        @conn.exec_params(<<~SQL, [id, position, attachment.filename, attachment.size, attachment.content])
          INSERT INTO attachments (message_id, position, filename, size, content) VALUES ($1, $2, $3, $4, $5)
        SQL
      end
      id
    end

    def max_seq(list)
      @conn.exec_params('SELECT max(seq) FROM messages WHERE list = $1', [list]).getvalue(0, 0)
    end

    def find(list, seq)
      @conn.exec_params("SELECT #{COLUMNS} FROM messages WHERE list = $1 AND seq = $2", [list, seq]).first
    end

    def rows(ids)
      rows = @conn.exec_params("SELECT #{COLUMNS} FROM messages WHERE id = ANY($1::bigint[])", [ids]).to_a
      rows.sort_by { |row| ids.index(row['id']) }
    end

    # What Search needs to know about the table it searches.
    def table = 'messages'

    def conditions(params, lists: nil, since: nil, before: nil, from: nil, include_notifications: false)
      sql = []
      sql << "list = ANY($#{params.push(lists).size}::text[])" if lists
      sql << "date >= $#{params.push(since).size}" if since
      sql << "date < $#{params.push(before).size}" if before
      if from
        n = params.push("%#{from.gsub(/[\\%_]/) { |c| "\\#{c}" }}%").size
        sql << "(from_name ILIKE $#{n} OR from_address ILIKE $#{n})"
      end
      sql << 'NOT notification' unless include_notifications
      sql
    end

    def document(row)
      Text.passage(row['subject'], row['body'])
    end

    def ref(id)
      @conn.exec_params('SELECT list, seq FROM messages WHERE id = $1', [id]).first
    end

    def children(id)
      @conn.exec_params('SELECT list, seq FROM messages WHERE parent_id = $1 ORDER BY date, list, seq', [id]).to_a
    end

    def attachments(id)
      @conn.exec_params('SELECT filename, size, content FROM attachments WHERE message_id = $1 ORDER BY position',
                        [id]).to_a
    end

    # A parent in the same list wins over one found in another list, then
    # In-Reply-To wins over References, nearest reference first. The body
    # citation is the last resort.
    def resolve_parents
      linked = @conn.exec(<<~SQL).cmd_tuples
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
      linked + @conn.exec(<<~SQL).cmd_tuples
        UPDATE messages m SET parent_id = p.id
        FROM messages p
        WHERE m.parent_id IS NULL AND p.list = m.cited_list AND p.seq = m.cited_seq AND p.id <> m.id
      SQL
    end

    def thread(id)
      root = @conn.exec_params(<<~SQL, [id]).getvalue(0, 0)
        WITH RECURSIVE up (id, parent_id, depth) AS (
          SELECT id, parent_id, 0 FROM messages WHERE id = $1
          UNION ALL
          SELECT m.id, m.parent_id, up.depth + 1 FROM messages m JOIN up ON m.id = up.parent_id WHERE up.depth < 100
        )
        SELECT id FROM up ORDER BY depth DESC LIMIT 1
      SQL
      @conn.exec_params(<<~SQL, [root, THREAD_LIMIT + 1]).to_a
        WITH RECURSIVE down (id, depth, path) AS (
          SELECT id, 0, ARRAY[id] FROM messages WHERE id = $1
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
        LIMIT $2
      SQL
    end
  end
end
