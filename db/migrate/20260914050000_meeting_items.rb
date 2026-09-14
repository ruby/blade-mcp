# frozen_string_literal: true

# Agenda items of the notes in ruby/dev-meeting-log, as a third source of
# statements.
Sequel.migration do
  up do
    run <<~SQL
      CREATE TABLE meeting_items (
        id bigserial PRIMARY KEY,
        path text NOT NULL,
        position integer NOT NULL,
        date date NOT NULL,
        heading text NOT NULL,
        body text NOT NULL,
        issue_id integer,
        statements_extracted_at timestamptz,
        UNIQUE (path, position)
      );

      ALTER TABLE statements ADD COLUMN meeting_item_id bigint REFERENCES meeting_items (id) ON DELETE CASCADE;
      ALTER TABLE statements DROP CONSTRAINT statements_check;
      ALTER TABLE statements ADD CONSTRAINT statements_one_source
        CHECK (num_nonnulls(message_id, journal_id, meeting_item_id) = 1);
      CREATE INDEX statements_meeting_item_id ON statements (meeting_item_id);
    SQL
  end
end
