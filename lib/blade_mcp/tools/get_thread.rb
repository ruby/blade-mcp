# frozen_string_literal: true

module BladeMcp
  module Tools
    class GetThread < MCP::Tool
      extend Helpers

      tool_name 'get_thread'
      description 'List the whole thread a message belongs to, from its root, in date order. Each entry has the ' \
                  'ref of its parent and its depth, but no body; read bodies with get_message. Replies are linked ' \
                  'by In-Reply-To and References, across lists when needed, and otherwise by a [list:number] ' \
                  "citation in the body. Threads longer than #{Store::THREAD_LIMIT} messages are truncated."
      input_schema(
        properties: {ref: {type: 'string', description: 'Ref of any message in the thread, such as [ruby-dev:30000]'}},
        required: ['ref']
      )
      annotations(READ_ONLY)

      def self.call(ref:, server_context:)
        store = server_context[:store]
        row = find_message(store, ref)
        return error_response("No such message: #{ref}") unless row
        rows = store.thread(row[:id])
        messages = rows.first(Store::THREAD_LIMIT).map do |message|
          parent = ref(message[:parent_list], message[:parent_seq]) if message[:parent_list]
          summary(message).merge(parent:, depth: message[:depth]).compact
        end
        json_response(root: messages.find { |message| message[:depth].zero? }&.dig(:ref), messages:,
                      truncated: rows.size > Store::THREAD_LIMIT)
      end
    end
  end
end
