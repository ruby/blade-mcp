CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS messages (
  id bigserial PRIMARY KEY,
  list text NOT NULL,
  seq integer NOT NULL,
  msgid text,
  reply_msgids text[] NOT NULL DEFAULT '{}',
  cited_list text,
  cited_seq integer,
  parent_id bigint REFERENCES messages (id) ON DELETE SET NULL,
  from_name text,
  from_address text,
  date timestamptz,
  subject text,
  body text,
  issue integer,
  notification boolean NOT NULL DEFAULT false,
  tsv tsvector NOT NULL,
  -- cohere-embed-v4 returns 1536 dimensions
  embedding vector(1536),
  UNIQUE (list, seq)
);

ALTER TABLE messages ADD COLUMN IF NOT EXISTS embedding_skipped boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS messages_msgid ON messages (msgid);
CREATE INDEX IF NOT EXISTS messages_parent_id ON messages (parent_id);
CREATE INDEX IF NOT EXISTS messages_tsv ON messages USING gin (tsv);
CREATE INDEX IF NOT EXISTS messages_embedding ON messages USING hnsw (embedding vector_cosine_ops);

CREATE TABLE IF NOT EXISTS attachments (
  message_id bigint NOT NULL REFERENCES messages (id) ON DELETE CASCADE,
  position integer NOT NULL,
  filename text NOT NULL,
  size integer NOT NULL,
  content text,
  PRIMARY KEY (message_id, position)
);
