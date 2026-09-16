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

    # The options both runners take, parsed into a hash. OUT_DIR is left in ARGV.
    def options(banner)
      options = {consultant: 'heroku', set: 'all', trials: 3, jobs: 4}
      parser = OptionParser.new do |opts|
        opts.banner = banner
        opts.on('--consultant NAME', 'heroku for the chat model of Heroku Managed Inference, or a Claude Code model such as opus')
        opts.on('--skill PATH', 'Give the consultant this skill along with the tools')
        opts.on('--set SET', %w[tune check all], 'Questions to ask: tune, check or all (default)')
        opts.on('--trials N', Integer, 'Answers per question and condition (default 3)')
        opts.on('--jobs N', Integer, 'Answers produced at once (default 4)')
        opts.on('--only ID,...', Array, 'Ask only these questions')
        opts.on('--baseline-from DIR', 'Take the answers without tools from an earlier run instead of asking again')
      end
      parser.parse!(into: options)
      [options, ARGV.fetch(0) { abort parser.help }]
    end

    def questions(name, options)
      load(name).select { |question| options[:set] == 'all' || question['set'] == options[:set] }
                .select { |question| !options[:only] || options[:only].include?(question['id']) }
    end

    # Returns a lambda that asks the consultant one question, with the tools or without them. The block gives the
    # system prompt for a question and condition. chat is the Heroku chat model, which the benchmark grades with in
    # either case, and which is the consultant itself unless a Claude Code model was named; sharing the one client
    # keeps the whole run within the requests a minute Heroku allows.
    def consultant(options, chat, &prompt)
      if options[:consultant] == 'heroku'
        statements = Statements.new(DB.connect)
        search = Search.new(statements, embedder: Inference::Embedding.from_env, reranker: Inference::Rerank.from_env)
        context = {statements:, matz_search: search}
        lambda do |question, request, tools|
          # A client passes on what the server says about itself at initialize, which Claude Code does by itself.
          system = tools ? "#{prompt.(question, true)}\n\n#{App::INSTRUCTIONS}" : prompt.(question, false)
          chat.ask(system, request, context:, date_to: question['date_to'], tools:)
        end
      else
        claude = ClaudeCode.new(options[:consultant])
        lambda do |question, request, tools|
          if tools
            mcp = {command: RbConfig.ruby, args: [File.join(__dir__, 'server.rb')], env: {BENCH_DATE_TO: question['date_to'].to_s}}
            allowed = %w[mcp__blade__search_matz mcp__blade__matz_timeline]
          end
          begin
            claude.ask(prompt.(question, tools), request, mcp:, allowed: allowed.to_a)
          rescue RuntimeError => e
            warn "#{question['id']}: asking again after #{e.message[0, 200]}"
            claude.ask(prompt.(question, tools), request, mcp:, allowed: allowed.to_a)
          end
        end
      end
    end

    # Runs the block for every question in both conditions, on as many threads as the options allow, and writes a
    # question's answers to its own file as soon as they are all in. A question whose file is already there is left
    # alone, so an interrupted run goes on where it stopped.
    def answers(questions, out, options)
      results = {}
      jobs = []
      questions.each do |question|
        path = File.join(out, "#{question['id']}.json")
        next if File.exist?(path)

        result = results[path] = question.merge('baseline' => Array.new(options[:trials]), 'tools' => Array.new(options[:trials]))
        if options[:'baseline-from']
          result['baseline'] = JSON.parse(File.read(File.join(options[:'baseline-from'], "#{question['id']}.json")))['baseline']
        else
          options[:trials].times { |trial| jobs << [question, path, 'baseline', trial] }
        end
        options[:trials].times { |trial| jobs << [question, path, 'tools', trial] }
      end

      lock = Mutex.new
      each_job(jobs, options[:jobs]) do |question, path, condition, trial|
        run = yield(question, condition, trial)
        lock.synchronize do
          result = results.fetch(path)
          result[condition][trial] = run
          File.write(path, JSON.pretty_generate(result)) if (result['baseline'] + result['tools']).none?(&:nil?)
        end
      end
    end

    def mean(values)
      values = values.compact
      values.empty? ? 0 : (values.sum.to_f / values.size).round(2)
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
