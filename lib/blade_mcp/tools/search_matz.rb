# frozen_string_literal: true

module BladeMcp
  module Tools
    class SearchMatz < MCP::Tool
      extend Helpers

      MAX_LIMIT = 50

      tool_name 'search_matz'
      description 'Search what Yukihiro Matsumoto (matz), the creator of Ruby, said about the design of Ruby: ' \
                  'statements drawn from his mails on the Ruby mailing lists, from bugs.ruby-lang.org comments by him ' \
                  'or reporting his decisions, and from the notes of the developers\' meetings in ruby/dev-meeting-log. ' \
                  'Each has a kind, an English summary and rationale, a verbatim quote in the original language, the ' \
                  'features it is about, and its source: a ref for get_message, an issue and note number on ' \
                  'bugs.ruby-lang.org, or a meeting notes file and agenda item. Query with a few words, or ' \
                  'with a whole proposal to find precedents for it. Matches are by words and by meaning, reranked.'
      input_schema(
        properties: {
          query: {type: 'string', description: 'Words, a question or a proposal'},
          **MATZ_FILTERS,
          limit: {type: 'integer', description: "Maximum number of results (default 10, max #{MAX_LIMIT})"}
        },
        required: ['query']
      )
      annotations(READ_ONLY)

      def self.call(query:, server_context:, kinds: nil, feature: nil, date_from: nil, date_to: nil,
                    include_reported: true, limit: 10)
        return error_response('query must not be empty') if query.strip.empty?
        since, before = date_range(date_from, date_to)
        rows = server_context[:matz_search].call(query, kinds:, feature:, since:, before:, include_reported:,
                                                        limit: limit.clamp(1, MAX_LIMIT))
        json_response(results: rows.map { |row| statement(row) })
      rescue Date::Error
        error_response('date_from and date_to must be YYYY-MM-DD')
      end
    end
  end
end
