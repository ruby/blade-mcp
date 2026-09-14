# frozen_string_literal: true

module BladeMcp
  module Tools
    class MatzTimeline < MCP::Tool
      extend Helpers

      MAX_LIMIT = 100

      tool_name 'matz_timeline'
      description 'List, oldest first, the statements search_matz returns for one feature, to follow how what matz ' \
                  'said about it changed over the years. total counts every match; when it exceeds the statements ' \
                  'returned, continue with a later date_from.'
      input_schema(
        properties: {
          **MATZ_FILTERS,
          limit: {type: 'integer', description: "Maximum number of statements (default 50, max #{MAX_LIMIT})"}
        },
        required: ['feature']
      )
      annotations(READ_ONLY)

      def self.call(feature:, server_context:, kinds: nil, date_from: nil, date_to: nil, include_reported: true,
                    limit: 50)
        return error_response('feature must not be empty') if feature.strip.empty?
        since, before = date_range(date_from, date_to)
        rows, total = server_context[:statements].timeline(kinds:, feature:, since:, before:, include_reported:,
                                                           limit: limit.clamp(1, MAX_LIMIT))
        json_response(total:, statements: rows.map { |row| statement(row) })
      rescue Date::Error
        error_response('date_from and date_to must be YYYY-MM-DD')
      end
    end
  end
end
