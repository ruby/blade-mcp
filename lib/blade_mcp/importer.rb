# frozen_string_literal: true

require_relative 'parser'

module BladeMcp
  class Importer
    BATCH = 100

    def initialize(store, vault, concurrency: 8, log: $stdout)
      @store = store
      @vault = vault
      @concurrency = concurrency
      @log = log
    end

    # With only_new, takes the keys above the highest number already stored
    # for each list. Parents are resolved once at the end so that replies can
    # find messages imported later from another list.
    def run(lists, limit: nil, only_new: false)
      imported = lists.sum do |list|
        seqs = @vault.seqs(list)
        if only_new && (max = @store.max_seq(list))
          seqs = seqs.select { |seq| seq > max }
        end
        seqs = seqs.first(limit) if limit
        @log.puts "#{list}: #{seqs.size} messages to import"
        seqs.each_slice(BATCH).sum { |slice| import(list, slice) }
      end
      linked = @store.resolve_parents
      @log.puts "imported #{imported} messages, linked #{linked} replies"
      imported
    end

    private

    # Fetch errors abort the run: skipping a message there would leave a hole
    # that the next incremental run never revisits. Messages that cannot be
    # parsed or stored would fail the same way again, so they are skipped.
    def import(list, seqs)
      saved = fetch(list, seqs).count do |message|
        @store.conn.transaction { @store.save(message) }
        true
      rescue PG::DataException, PG::ProgramLimitExceeded => e
        @log.puts "#{list}:#{message.seq} not saved: #{e.message.lines.first&.strip}"
        false
      end
      @log.puts "#{list}: up to #{seqs.last}"
      saved
    end

    def fetch(list, seqs)
      queue = Queue.new(seqs).close
      Array.new(@concurrency) do
        Thread.new do
          Thread.current.report_on_exception = false # Thread#value raises it in the caller
          messages = []
          while (seq = queue.pop)
            message = parse(list, seq, @vault.fetch(list, seq))
            messages << message if message
          end
          messages
        end
      end.flat_map(&:value).sort_by(&:seq)
    end

    def parse(list, seq, raw)
      if raw.nil? || raw.empty?
        @log.puts "#{list}:#{seq} is missing or empty, skipped"
        return
      end
      Parser.parse(raw, list, seq)
    rescue StandardError => e
      @log.puts "#{list}:#{seq} not parsed: #{e.class}: #{e.message}"
      nil
    end
  end
end
