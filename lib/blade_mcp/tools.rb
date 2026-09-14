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
        name, address = row.values_at(:from_name, :from_address)
        {
          ref: ref(row[:list], row[:seq]),
          from: name && address ? "#{name} <#{address}>" : name || address,
          date: row[:date]&.getutc&.iso8601,
          subject: row[:subject],
          issue: row[:issue],
          notification: (true if row[:notification])
        }.compact
      end

      # Mails are cited by ref, bugs.ruby-lang.org comments by issue and note
      # number, and meeting notes by their file in ruby/dev-meeting-log and
      # the agenda heading, with links reduced to their text.
      def statement(row)
        {
          kind: row[:kind],
          topic: row[:topic],
          summary: row[:summary],
          rationale: row[:rationale],
          quote: row[:quote],
          features: row[:features].to_a,
          date: row[:date]&.getutc&.iso8601,
          ref: (ref(row[:list], row[:seq]) if row[:list]),
          issue: row[:issue_id],
          note: row[:note_number],
          meeting: row[:meeting],
          agenda: (row[:agenda].gsub(/\[(\[[^\]]*\]|[^\]]*)\]\(https?:[^)]*\)/, '\1') unless row[:agenda].to_s.empty?),
          reported_by: (row[:author_name] if row[:reported])
        }.compact
      end

      # Returns the start of date_from and the end of date_to, in UTC.
      def date_range(date_from, date_to)
        [utc_date(date_from), utc_date(date_to)&.+(86_400)]
      end

      def utc_date(value)
        return unless value
        date = Date.iso8601(value)
        Time.utc(date.year, date.month, date.day)
      end
    end

    DATES = {
      date_from: {type: 'string', description: 'Earliest date, YYYY-MM-DD in UTC'},
      date_to: {type: 'string', description: 'Latest date, YYYY-MM-DD in UTC, inclusive'}
    }.freeze

    MATZ_FILTERS = {
      kinds: {
        type: 'array', items: {type: 'string', enum: Statements::KINDS},
        description: 'Only these kinds: accepted or rejected proposals, design and naming settled, policy, opinion ' \
                     'without settling, undecided (put off), condition (what a proposal needs to be accepted), and ' \
                     'principle (a design value beyond the case)'
      },
      feature: {
        type: 'string',
        description: 'Only statements whose topic or features contain this, ignoring case, such as Ractor, JIT or Hash#fetch'
      },
      **DATES,
      include_reported: {
        type: 'boolean',
        description: 'Also return what others reported matz said, such as dev meeting notes (default true)'
      }
    }.freeze

    def self.all
      [Search, GetMessage, GetThread, SearchMatz, MatzTimeline]
    end
  end
end

require_relative 'tools/search'
require_relative 'tools/get_message'
require_relative 'tools/get_thread'
require_relative 'tools/search_matz'
require_relative 'tools/matz_timeline'
