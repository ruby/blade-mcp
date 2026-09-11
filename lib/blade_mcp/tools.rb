# frozen_string_literal: true

require 'date'
require 'json'
require 'mcp'

module BladeMcp
  module Tools
    READ_ONLY = {read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false}.freeze
    REF = /\A\[?\s*(ruby-[a-z]+)\s*:\s*(\d+)\s*\]?\z/

    module Helpers
      def json_response(payload)
        MCP::Tool::Response.new([{type: 'text', text: JSON.generate(payload)}])
      end

      def error_response(message)
        MCP::Tool::Response.new([{type: 'text', text: message}], error: true)
      end

      def ref(list, seq)
        "[#{list}:#{seq}]"
      end

      def find_message(store, value)
        list, seq = value.to_s.strip.match(REF)&.captures
        store.find(list, seq.to_i) if list
      end

      def summary(row)
        name, address = row.values_at('from_name', 'from_address')
        {
          ref: ref(row['list'], row['seq']),
          from: name && address ? "#{name} <#{address}>" : name || address,
          date: row['date']&.getutc&.iso8601,
          subject: row['subject'],
          issue: row['issue'],
          notification: (true if row['notification'])
        }.compact
      end
    end

    def self.all
      [Search, GetMessage, GetThread]
    end
  end
end

require_relative 'tools/search'
require_relative 'tools/get_message'
require_relative 'tools/get_thread'
