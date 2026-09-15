# frozen_string_literal: true

require 'bundler/setup'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'tmpdir'
require 'yaml'
require_relative '../lib/blade_mcp'

module BladeMcp
  # What the benchmarks in this directory share.
  module Bench
    ROOT = File.expand_path('..', __dir__)
    SKILL = File.join(ROOT, 'skills/blade/SKILL.md')

    module_function

    def load(name)
      YAML.load_file(File.join(__dir__, name), permitted_classes: [Date])
    end

    def patiently
      10.times do
        return yield
      rescue Inference::RateLimited => e
        sleep(e.retry_after || 60)
      end
      yield
    end

    # Calls the block with each job on this many threads at once.
    def each_job(jobs, threads)
      queue = Queue.new
      jobs.each { |job| queue << job }
      queue.close
      Array.new(threads) do
        Thread.new do
          while (job = queue.pop)
            yield job
          end
        end
      end.each(&:join)
    end

    # Has the chat model grade with a forced call of the given tool, and returns its arguments.
    def grade(chat, user, tool)
      patiently { chat.call_tool('You grade strictly and briefly.', user, tool, max_tokens: 1000) }.first
    end

    def parse(text)
      JSON.parse(text)
    rescue JSON::ParserError
      text
    end

    # Claude Code as the users of the MCP server run it, but without the settings, CLAUDE.md and skills of whoever
    # runs the benchmark. --safe-mode would leave those out at once, but it drops the MCP server as well.
    class ClaudeCode
      def initialize(model, bin: ENV.fetch('CLAUDE_BIN', 'claude'))
        @model = model
        @bin = bin
      end

      # Returns the answer, the tool calls with their results, the cost Claude Code reports and the model it used. With
      # no mcp, the blade MCP server is not connected at all.
      def ask(system, request, mcp: nil, allowed: [], builtin: '')
        args = [@bin, '-p', '--model', @model, '--setting-sources', '', '--disable-slash-commands', '--no-session-persistence',
                '--output-format', 'stream-json', '--verbose', '--tools', builtin, '--strict-mcp-config',
                '--allowedTools', allowed.join(','), '--system-prompt', system]
        args += ['--mcp-config', JSON.generate(mcpServers: {blade: mcp})] if mcp
        # The request goes through stdin, since the variadic --tools and --allowedTools would take it as a tool name.
        out, err, status = Dir.mktmpdir { |dir| Open3.capture3(*args, stdin_data: request, chdir: dir) }
        events = out.each_line.filter_map { |line| Bench.parse(line) }.grep(Hash)
        init = events.find { |event| event['subtype'] == 'init' }
        result = events.find { |event| event['type'] == 'result' }
        raise "claude exited #{status.exitstatus}: #{err[0, 300]}" unless init && result
        if mcp && init['mcp_servers'].none? { |server| server['name'] == 'blade' && server['status'] == 'connected' }
          raise "the blade MCP server did not connect: #{init['mcp_servers']}"
        end

        blocks = ->(type) { events.select { |event| event['type'] == type }.flat_map { |event| event.dig('message', 'content').to_a }.grep(Hash) }
        outputs = blocks.('user').select { |block| block['type'] == 'tool_result' }.to_h do |block|
          [block['tool_use_id'], Array(block['content']).map { |part| part.is_a?(Hash) ? part['text'] : part }.join]
        end
        calls = blocks.('assistant').select { |block| block['type'] == 'tool_use' }.map do |use|
          {tool: use['name'].delete_prefix('mcp__blade__'), input: use['input'], output: Bench.parse(outputs[use['id']].to_s)}
        end
        {answer: result['result'].to_s.strip, calls:, cost_usd: result['total_cost_usd'], model: init['model']}
      end
    end

    # The chat model of Heroku Managed Inference, calling search_matz and matz_timeline in process.
    class HerokuConsultant < Inference::Chat
      TOOLS = [Tools::SearchMatz, Tools::MatzTimeline].freeze
      SPECS = TOOLS.map do |tool|
        spec = tool.to_h
        {type: 'function', function: {name: spec[:name], description: spec[:description], parameters: spec[:inputSchema].except(:$schema)}}
      end.freeze
      MAX_TURNS = 8

      # Returns the answer and the tool calls with their results. Nothing dated after date_to reaches the model.
      def ask(system, request, context:, date_to:, tools:)
        messages = [{role: 'system', content: system}, {role: 'user', content: request}]
        calls = []
        MAX_TURNS.times do
          text, requested = Bench.patiently { turn(messages, tools ? SPECS : []) }
          return {answer: text.strip, calls:, model: @model} if requested.empty?

          # Heroku rejects an assistant message that has tool calls but no content.
          messages << {role: 'assistant', content: text.empty? ? '(looking this up)' : text,
                       tool_calls: requested.map { |call| {id: call['id'], type: 'function', function: call.slice('name', 'arguments')} }}
          requested.each do |call|
            output = call_tool_locally(call, context, date_to)
            calls << {tool: call['name'], input: Bench.parse(call['arguments']), output: Bench.parse(output)}
            messages << {role: 'tool', tool_call_id: call['id'], content: output}
          end
        end
        {answer: "(no answer after #{MAX_TURNS} turns)", calls:, model: @model}
      end

      private

      def turn(messages, tools)
        payload = {model: @model, max_completion_tokens: 4000,
                   messages: messages.map { |m| m[:content].is_a?(String) ? m.merge(content: defuse(m[:content])) : m }}
        payload[:tools] = tools unless tools.empty?
        text = +''
        calls = []
        pace
        stream('/v1/chat/completions', payload) do |event|
          delta = event.dig('choices', 0, 'delta') || {}
          text << delta['content'].to_s
          delta['tool_calls']&.each do |part|
            call = calls[part['index'] || 0] ||= {'id' => nil, 'name' => nil, 'arguments' => +''}
            call['id'] ||= part['id'] unless part['id'].to_s.empty?
            call['name'] ||= part.dig('function', 'name') unless part.dig('function', 'name').to_s.empty?
            call['arguments'] << part.dig('function', 'arguments').to_s
          end
        end
        [text, calls.compact]
      end

      def call_tool_locally(call, context, date_to)
        tool = TOOLS.find { |t| t.to_h[:name] == call['name'] } or return "Unknown tool #{call['name']}"
        arguments = JSON.parse(call['arguments'].empty? ? '{}' : call['arguments'])
        arguments = arguments.slice(*tool.to_h.dig(:inputSchema, :properties).keys.map(&:to_s))
        arguments['date_to'] = [arguments['date_to'], date_to.to_s].compact.min
        tool.call(**arguments.transform_keys(&:to_sym), server_context: context).content.first[:text]
      rescue JSON::ParserError, ArgumentError => e
        "Tool error: #{e.message}"
      end
    end
  end
end
