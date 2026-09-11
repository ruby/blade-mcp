# frozen_string_literal: true

module BladeMcp
  module Tools
    class GetMessage < MCP::Tool
      extend Helpers

      tool_name 'get_message'
      description 'Read one message of the Ruby mailing list archive: sender, date, subject, the decoded body, ' \
                  'attachments (text ones such as patches in full, binary ones by name and size only), and the refs ' \
                  'of its parent and replies. Redmine notification mails have no body here; read the issue with the ' \
                  'bugs.ruby-lang.org MCP server instead.'
      input_schema(
        properties: {ref: {type: 'string', description: 'Message ref such as [ruby-dev:30000] or ruby-dev:30000'}},
        required: ['ref']
      )
      annotations(READ_ONLY)

      def self.call(ref:, server_context:)
        store = server_context[:store]
        row = find_message(store, ref)
        return error_response("No such message: #{ref}") unless row
        parent = store.ref(row['parent_id']) if row['parent_id']
        attachments = store.attachments(row['id']).map do |attachment|
          {filename: attachment['filename'], size: attachment['size'], content: attachment['content']}.compact
        end
        json_response(summary(row).merge(
          parent: parent && ref(parent['list'], parent['seq']),
          replies: store.children(row['id']).map { |child| ref(child['list'], child['seq']) },
          body: row['body'],
          attachments:
        ).compact)
      end
    end
  end
end
