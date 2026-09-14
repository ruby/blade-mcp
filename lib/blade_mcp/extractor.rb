# frozen_string_literal: true

require_relative 'inference'
require_relative 'patience'
require_relative 'statements'
require_relative 'text'

module BladeMcp
  # Has the chat model read matz's mails, the bugs.ruby-lang.org comments by
  # or about him and the agenda items of the developers' meeting notes, and
  # stores what he said as statements. Each is read once, unless its text
  # changes on a later import.
  class Extractor
    include Patience

    SOURCES = %w[ml redmine meeting].freeze
    BATCH = 20
    CONTEXT_CHARS = 3000
    TARGET_CHARS = 12_000
    # A few agenda items hold a whole IRC log or a long discussion, where
    # matz may speak last.
    MEETING_CHARS = 40_000
    QUOTE_CHARS = 500
    # Addresses are stored with their domain masked, and another matz@ once
    # posted as "Eye Matz".
    MATZ_MAILS = "m.from_address = 'matz@...' AND coalesce(m.from_name, '') IN ('Yukihiro Matsumoto', 'matz', 'matz@...', '')"

    SYSTEM = <<~TEXT
      You read posts from the Ruby mailing lists, comments on bugs.ruby-lang.org and the notes of the Ruby developers' meetings, and record what Yukihiro Matsumoto (matz), the creator of Ruby, said about the design of Ruby and its standard library.

      Record a statement for each point where matz, in the target:
      - accepts or rejects a proposal or change (accepted, rejected)
      - settles how a feature behaves (design), or what something is named, including names he turns down (naming)
      - sets a policy on releases, compatibility, licensing or process (policy)
      - gives a view or a concern about a feature without settling it (opinion)
      - puts a question off, or says he has not made up his mind (undecided)
      - states what a proposal needs before he would accept it (condition)
      - states a design value that reaches beyond the case at hand (principle)

      Do not record merging or committing a patch, bug analysis, plain questions, release schedules, or anything said by someone other than matz. When the target was written by someone else, record only what it reports matz said or decided, such as meeting notes.

      Use the context only to understand what the target refers to. Write topic, summary and rationale in English, and leave rationale empty when the target gives no reason. Copy quote verbatim from the target in its original language. List in features the Ruby classes, modules, methods, syntax or subsystems the statement is about, spelled as Ruby spells them, such as Ractor, YJIT, Ruby::Box, Hash#fetch or refinements. Call record_statements exactly once, with an empty list when the target holds nothing to record.
    TEXT

    TOOL = {
      type: 'function',
      function: {
        name: 'record_statements',
        description: 'Record what matz said in the target.',
        parameters: {
          type: 'object',
          properties: {
            statements: {
              type: 'array',
              items: {
                type: 'object',
                properties: {
                  kind: {type: 'string', enum: Statements::KINDS},
                  topic: {type: 'string', description: 'What the statement is about, as a short noun phrase'},
                  summary: {type: 'string', description: 'What matz said, in one to three sentences'},
                  rationale: {type: 'string', description: 'The reason matz gave, or an empty string'},
                  quote: {type: 'string', description: "The words in the target that carry the statement, verbatim, at most #{QUOTE_CHARS} characters"},
                  features: {type: 'array', items: {type: 'string'}}
                },
                required: %w[kind topic summary rationale quote features]
              }
            }
          },
          required: ['statements']
        }
      }
    }.freeze

    def initialize(conn, client, concurrency: 4, log: $stdout)
      @conn = conn
      @client = client
      @concurrency = concurrency
      @log = log
    end

    def run(sources: SOURCES, limit: nil)
      sources.sum { |source| run_source(source, limit) }
    end

    private

    def run_source(source, limit)
      done = 0
      found = 0
      tokens = 0
      failed = []
      loop do
        size = [BATCH, limit && limit - done].compact.min
        break unless size.positive?
        items = candidates(source, size, failed)
        break if items.empty?
        results = read(items)
        @conn.transaction do
          results.each do |item, statements, usage|
            unless statements
              failed << item[:id]
              next
            end
            store(source, item, statements)
            found += statements.size
            tokens += usage.to_h.fetch('total_tokens', 0)
          end
        end
        done += items.size
        @log.puts "#{source}: read #{done}, #{found} statements, #{tokens} tokens"
      end
      done
    end

    def candidates(source, size, failed)
      if source == 'ml'
        @conn.exec_params(<<~SQL, [size, failed]).map { |row| mail_item(row) }
          SELECT m.id, m.list, m.seq, m.date, m.subject, m.body, p.list AS parent_list, p.seq AS parent_seq,
                 p.from_name AS parent_from, p.subject AS parent_subject, p.body AS parent_body
          FROM messages m LEFT JOIN messages p ON p.id = m.parent_id
          WHERE m.statements_extracted_at IS NULL AND NOT m.notification AND #{MATZ_MAILS} AND m.id <> ALL($2::bigint[])
          ORDER BY m.id
          LIMIT $1
        SQL
      elsif source == 'redmine'
        @conn.exec_params(<<~SQL, [size, failed]).map { |row| note_item(row) }
          SELECT * FROM redmine_notes
          WHERE statements_extracted_at IS NULL AND journal_id <> ALL($2::integer[])
          ORDER BY journal_id
          LIMIT $1
        SQL
      else
        @conn.exec_params(<<~SQL, [size, failed]).map { |row| meeting_item(row) }
          SELECT * FROM meeting_items
          WHERE statements_extracted_at IS NULL AND id <> ALL($2::bigint[])
          ORDER BY id
          LIMIT $1
        SQL
      end
    end

    def mail_item(row)
      context =
        if row['parent_seq']
          "Parent post [#{row['parent_list']}:#{row['parent_seq']}] by #{row['parent_from']}\n" \
            "Subject: #{row['parent_subject']}\n\n#{Text.without_quotes(row['parent_body'])[0, CONTEXT_CHARS]}"
        else
          'No parent post was found.'
        end
      target = "Post [#{row['list']}:#{row['seq']}] by Yukihiro Matsumoto (matz) on #{row['date']&.getutc&.strftime('%F')}\n" \
               "Subject: #{row['subject']}\n\n#{row['body'].to_s[0, TARGET_CHARS]}"
      {id: row['id'], date: row['date'], reported: false, prompt: prompt(context, target)}
    end

    def note_item(row)
      context = "Issue ##{row['issue_id']} (#{row['tracker']}): #{row['issue_subject']}\n\n" \
                "#{row['issue_description'].to_s[0, CONTEXT_CHARS]}"
      if row['previous_notes']
        context += "\n\nPrevious comment by #{row['previous_author']}:\n#{row['previous_notes'][0, CONTEXT_CHARS]}"
      end
      target = "Comment #note-#{row['note_number']} on issue ##{row['issue_id']} by #{row['author_name']} " \
               "on #{row['created_on'].getutc.strftime('%F')}\n\n#{row['notes'][0, TARGET_CHARS]}"
      {id: row['journal_id'], date: row['created_on'], reported: !row['by_matz'], prompt: prompt(context, target)}
    end

    def meeting_item(row)
      date = row['date']
      context = "Notes of the Ruby developers' meeting on #{date.iso8601}, written by the attendees and kept as " \
                "#{row['path']} in ruby/dev-meeting-log. The meeting is where proposals get matz's agreement."
      heading = row['heading'].empty? ? 'the part of the notes before any heading' : "the agenda item \"#{row['heading']}\""
      target = "From #{heading}\n\n#{row['body'][0, MEETING_CHARS]}"
      {id: row['id'], date: Time.utc(date.year, date.month, date.day), reported: true, prompt: prompt(context, target)}
    end

    def prompt(context, target)
      "<context>\n#{context}\n</context>\n\n<target>\n#{target}\n</target>"
    end

    # Returns [item, statements, usage] in the order of items, with nil
    # statements when the model could not be asked.
    def read(items)
      queue = Queue.new(items.each_with_index.to_a).close
      results = Array.new(items.size)
      Array.new([@concurrency, items.size].min) do
        Thread.new do
          Thread.current.report_on_exception = false
          while (pair = queue.pop)
            item, index = pair
            results[index] = [item, *ask(item)]
          end
        end
      end.each(&:value)
      results
    end

    def ask(item)
      arguments, usage = patiently { @client.call_tool(SYSTEM, item[:prompt], TOOL) }
      [statements(arguments), usage]
    rescue Inference::Blocked
      @log.puts "#{item[:id]} was blocked, recorded without statements"
      [[], nil]
    rescue Inference::Error => e
      @log.puts "#{item[:id]} not read: #{e.message}"
      [nil, nil]
    end

    def statements(arguments)
      Array(arguments['statements']).filter_map do |statement|
        next unless statement.is_a?(Hash) && Statements::KINDS.include?(statement['kind'])
        topic, summary, rationale, quote = statement.values_at('topic', 'summary', 'rationale', 'quote').map { |s| s.to_s.strip }
        next if topic.empty? || summary.empty? || quote.empty?
        features = Array(statement['features']).map { |f| f.to_s.strip }.reject(&:empty?).uniq
        {kind: statement['kind'], topic:, summary:, rationale: (rationale unless rationale.empty?),
         quote: quote[0, QUOTE_CHARS], features:}
      end
    end

    def store(source, item, statements)
      column, table, key = {'ml' => %w[message_id messages id], 'redmine' => %w[journal_id redmine_notes journal_id],
                            'meeting' => %w[meeting_item_id meeting_items id]}.fetch(source)
      @conn.exec_params("DELETE FROM statements WHERE #{column} = $1", [item[:id]])
      corpus = Statements.new(@conn)
      statements.each do |statement|
        corpus.insert(column, item[:id], statement, date: item[:date], reported: item[:reported], model: @client.model)
      end
      @conn.exec_params("UPDATE #{table} SET statements_extracted_at = now() WHERE #{key} = $1", [item[:id]])
    end
  end
end
