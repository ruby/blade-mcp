# frozen_string_literal: true

module BladeMcp
  module Tools
    class Search < MCP::Tool
      extend Helpers

      MAX_LIMIT = 50

      tool_name 'search'
      description 'Search the Ruby mailing list archive (ruby-core, ruby-dev, ruby-list, ruby-talk, ruby-ext and ' \
                  'ruby-math, since 1995) for past discussions and decisions. Japanese and English both work: every ' \
                  'word must appear, and a double-quoted phrase must appear as written. Results are also matched by ' \
                  'meaning and reranked. Each result has a ref such as [ruby-dev:30000] for get_message and ' \
                  'get_thread, and the bugs.ruby-lang.org issue number when the mail is tied to one.'
      input_schema(
        properties: {
          query: {type: 'string', description: 'Words to search for'},
          lists: {type: 'array', items: {type: 'string', enum: LISTS}, description: 'Only these lists'},
          date_from: {type: 'string', description: 'Earliest date, YYYY-MM-DD in UTC'},
          date_to: {type: 'string', description: 'Latest date, YYYY-MM-DD in UTC, inclusive'},
          include_notifications: {
            type: 'boolean',
            description: 'Also return Redmine notification mails, which keep only the subject and the issue number ' \
                         '(default false). Read those issues with the bugs.ruby-lang.org MCP server.'
          },
          limit: {type: 'integer', description: "Maximum number of results (default 10, max #{MAX_LIMIT})"}
        },
        required: ['query']
      )
      annotations(READ_ONLY)

      def self.call(query:, server_context:, lists: nil, date_from: nil, date_to: nil, include_notifications: false,
                    limit: 10)
        return error_response('query must not be empty') if query.strip.empty?
        since = utc_date(date_from)
        before = utc_date(date_to)&.+(86_400)
        rows = server_context[:search].call(query, lists:, since:, before:, include_notifications:,
                                                   limit: limit.clamp(1, MAX_LIMIT))
        words = Bigram.words(query)
        results = rows.map do |row|
          summary(row).merge(snippet: (Text.snippet(row['body'], words) if row['body'])).compact
        end
        json_response(results:)
      rescue Date::Error
        error_response('date_from and date_to must be YYYY-MM-DD')
      end

      def self.utc_date(value)
        return unless value
        date = Date.iso8601(value)
        Time.utc(date.year, date.month, date.day)
      end
    end
  end
end
